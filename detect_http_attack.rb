#!/usr/bin/env ruby
#
# Detect HTTP attack
#
# A tool to detect attacks to HTTP server (Apache, Nginx),
# by analyzing the sequential access parsing combined log or LTSV log.
#
# Author::    Toshimitsu Takahashi (mailto:tilfin@gmail.com)
# Copyright:: (c) 2013 Toshimitsu Takahashi
# License::   MIT License
#

require 'date'
require 'optparse'


class LogParser

  def parse(line)
  end

end


class CombinedLogParser < LogParser

  def parse(line)
    row = line.to_s.chomp
    row.strip!
    m = parse_line(row)
    return nil if m.length == 0

    host, ident, user, time, req, status, size, referer, ua = m
    method, path = req.split(' ')

    { :host => host,
      :time => time,
      :date => parse_datetime(time),
      :req  => req,
      :method => method,
      :path => path,
      :status => status,
      :size => size,
      :referer => referer,
      :ua => ua }
  end

  def parse_datetime(dt_str)
    DateTime.strptime(dt_str, '%d/%b/%Y:%T %z')   
  end

  def parse_line(line)
    str = line
    values = Array.new

    while str
      first_char = str[0]

      if first_char == '"'
        start_pos = 1
        last_char = '"'
      elsif first_char == '['
        start_pos = 1
        last_char = ']'
      else
        start_pos = 0
        last_char = ' '
      end

      end_pos = str.index(last_char, 1)
  
      unless end_pos
        values.push str[start_pos..-1]
        break
      end

      values.push str[start_pos..end_pos-1]

      end_pos += start_pos
      str = str[end_pos+1 .. -1]
    end

    values
  end

end


class LtsvLogParser < LogParser

  def parse(line)
    row = line.to_s.chomp
    row.strip!
    return nil if row.length == 0

    values = Hash.new
    row.split("\t").map { |field|
      name, value = field.split(":", 2)
      values[name.to_sym] = value
    }

    method, path = values[:req].split(' ')
    values[:method] = method
    values[:path] = path
    values[:date] = parse_datetime(values[:time])

    values
  end

  def parse_datetime(dt_str)
    DateTime.strptime(dt_str, '[%d/%b/%Y:%T %z]')
  end

end


class Configuration
  
  def initialize(file_path=nil)
    conf_file = file_path || File.dirname(__FILE__) + "/detect_http_attack.conf"
    return unless File.exists?(conf_file)

    @sets = Hash.new

    open(conf_file, "r") do |f|
      f.each {|line|
        next if line.start_with?("#")

        name, value = line.split("=", 2)
        next unless value

        value = eval %Q{"#{value}"}
        @sets[name.to_sym] = value.chomp
      }
    end
  end

  def get(field)
    @sets[field]
  end

end


class Template

  def initialize(head, body, foot)
    @re_field = Regexp.new("\\$[a-z]+")

    h = head || "$host\\t$count\\t$ua"
    b = body || "$date\\t$path\\t$referer"
    f = foot || ""

    @head = parse_value(h)
    @body = parse_value(b)
    @foot = parse_value(f)
  end

  def  parse_value(value)
    vals = Array.new
    str = value

    begin  
      pos = @re_field =~ str
      if pos
        if pos > 0
          vals.push(str[0, pos])
        end

        fld = Regexp.last_match(0)
        vals.push(fld[1..-1].to_sym)

        pos += fld.length
        str = str[pos..-1]
      end
    end while pos

    if str
      vals.push(str)
    end

    vals
  end

  def print_head(ops, count, row)
    if @head
      print_row(@head, ops, count, row)
    end
  end

  def print_body(ops, row)
    print_row(@body, ops, "", row)
  end

  def print_foot(ops, count, row)
    if @foot
      print_row(@foot, ops, count, row)
    end
  end

  def print_row(templ, ops, count, row)
    templ.each do |val|
      if val.instance_of?(String)
        ops.print val
        next
      end

      if val == :count
        ops.print count.to_s
      else
        v = row[val]
        ops.print(v ? v.to_s : "")
      end
    end
  end

end


class DetectionProcessor

  attr :interval_threshold, true
  attr :sequence_threshold, true
  attr :exc_hosts, true
  attr :exc_ua, true
  attr :exc_path,  true

  def initialize(template)
    @template = template

    @interval_threshold = 3
    @sequence_threshold = 8

    @exc_hosts = []
    @exc_ua = nil
    @exc_path = nil

    @pre_access_map = Hash.new
    @ops = STDOUT
  end

  def proc(row)
    host = row[:host]
    return if @exc_hosts.index(host)
    return if @exc_ua and @exc_ua.match(row[:ua])

    path, query = row[:path].split("?")
    return if @exc_path and @exc_path.match(path)

    date_ts = row[:date].to_time.to_i

    if @pre_access_map.include?(host)
      ts, al = @pre_access_map[host]
      if (date_ts - ts) <= @interval_threshold
        al.push(row)
        @pre_access_map.store(host, [date_ts, al])
      else
        if al.count >= @sequence_threshold
          print_access(host, al)
        end
        @pre_access_map.store(host, [date_ts, [row]])
      end
    else
      @pre_access_map.store(host, [date_ts, [row]])
    end
  end

  def finalize
    @pre_access_map.each_pair do |host, values|
      al = values[1]
      next if al.count < @sequence_threshold

      print_access(host, al)
    end
  end

  def print_access(host, al)
    fl = al[0]

    @template.print_head(@ops, al.count, fl)

    al.each do |row|
      @template.print_body(@ops, row)
    end

    @template.print_foot(@ops, al.count, fl)
  end
end



def get_opts
  # Settting from Arguments 

  opts = { :parser => 'combined', :max_interval => 3, :min_seq => 8 }

  opt = OptionParser.new
  
  opt.on('-ltsv', 'Log type is LTSV') { |v| opts[:parser] = "ltsv" }
  
  opt.on('-s COUNT', 'Specify minimum sequential count') do |count|
    opts[:min_seq] = count.to_i
  end
  
  opt.on('-i SECONDS', 'Specify maximum interval seconds') do |sec|
    opts[:max_interval] = sec.to_i
  end
  
  opt.on('-f CONFFILE',
         'Specify configuration file') do |path|
    opts[:conf_file] = path
  end
  
  opt.parse!(ARGV)

  opts
end 
  
def main
  opts = get_opts

  if opts[:parser] == "ltsv"
    parser = LtsvLogParser.new
  else
    parser = CombinedLogParser.new
  end

  conf = Configuration.new(opts[:conf_file])

  template = Template.new(conf.get(:head), conf.get(:body), conf.get(:foot))

  processor = DetectionProcessor.new(template)
  processor.interval_threshold = opts[:max_interval]
  processor.sequence_threshold = opts[:min_seq]

  exc_hosts = conf.get(:exc_hosts)
  if exc_hosts
    processor.exc_hosts = exc_hosts.split(",")
  end
  
  exc_ua = conf.get(:exc_ua_match)
  if exc_ua
    processor.exc_ua = Regexp.new(exc_ua, "i")
  end

  exc_path = conf.get(:exc_path_match)
  if exc_path
    processor.exc_path = Regexp.new(exc_path)
  end

  #
  # Parsing log line, detect attacks
  #
  while line = STDIN.gets
    row = parser.parse(line)
    next unless row
  
    processor.proc(row)
  end
    
  processor.finalize
end

main

