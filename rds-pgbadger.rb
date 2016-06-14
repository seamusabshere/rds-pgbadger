#!/usr/bin/env ruby

require 'optparse'
require 'yaml'
require 'ox'
require 'aws-sdk-core'

require 'vault'
require 'redis'
require 'lock_and_cache'
LockAndCache.storage = Redis.new

options = {}
OptionParser.new do |opts|
    opts.banner = "Usage: rds-pgbadger.rb [options]"

    opts.on('-e', '--env NAME', 'Environement name') { |v| options[:env] = v }
    opts.on('-i', '--instance-id NAME', 'RDS instance identifier') { |v| options[:instance_id] = v }
    opts.on('-d', '--date DATE', 'Filter logs to given date in format YYYY-MM-DD.') { |v| options[:date] = v }

end.parse!

raise OptionParser::MissingArgument.new(:env) if options[:env].nil?
raise OptionParser::MissingArgument.new(:instance_id) if options[:instance_id].nil?

def creds
  @creds ||= LockAndCache.lock_and_cache('rdspgbadger-creds', expires: 86_400) do
    memo = Vault.logical.read('aws/creds/administrator').data
    sleep 5 # let the key start to work
    memo
  end
end

puts "Instantiating RDS client for #{options[:env]} environment."
rds = Aws::RDS::Client.new(
  region: 'us-east-1',
  access_key_id: creds[:access_key],
  secret_access_key: creds[:secret_key]
)
log_files = rds.describe_db_log_files(db_instance_identifier: options[:instance_id], filename_contains: "postgresql.log.#{options[:date]}")[:describe_db_log_files].map(&:log_file_name)

dir_name = "#{options[:instance_id]}-#{options[:date]}-#{Time.now.to_i}"

Dir.mkdir("out/#{dir_name}")
Dir.mkdir("out/#{dir_name}/error")
log_files.each do |log_file|
  puts "Downloading log file: #{log_file}"
  open("out/#{dir_name}/#{log_file}", 'w') do |f|
    rds.download_db_log_file_portion(db_instance_identifier: options[:instance_id], log_file_name: log_file, marker: '0', number_of_lines: 9999).each do |r|
      print "."
      f.puts r[:log_file_data]
    end
    puts "."
  end
  puts "Saved log to out/#{dir_name}/#{log_file}."
end
puts "Generating PG Badger report."
`pgbadger --prefix "%t:%r:%u@%d:[%p]:" --outfile out/#{dir_name}/#{dir_name}.html out/#{dir_name}/error/*.log.*`
puts "Opening report out/#{dir_name}/#{dir_name}.html."
`open out/#{dir_name}/#{dir_name}.html`

