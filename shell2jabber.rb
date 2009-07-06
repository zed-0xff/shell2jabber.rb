#!/usr/bin/ruby
require 'rubygems'
require 'yaml'
require 'xmpp4r-simple'
require 'pp'

VERSION=0.5

=begin

TODO:
	* multiple sessions

=end

cfg=YAML::load_file($0.sub(/\.rb$/,'')+'.yml')

throw :JidNotGiven if cfg['jid'].nil?
throw :PassNotGiven if cfg['pass'].nil?

Jabber::debug = cfg['debug']

def old_register cfg
  puts "[.] trying to register.."
  im = Jabber::Client.new(cfg['jid'])
  im.connect
  #info = im.register_info
  login = cfg['jid'][/^[^@]+/]
  im.register cfg['pass'], {
    :username => login,
#    :nick     => login,
    :password => cfg['pass']
#    :date     => Date.today
  }
  puts "[.] done"
  pp im
  exit 1
end

im = nil
begin
  im = Jabber::Simple.new(cfg['jid'], cfg['pass'])
rescue Jabber::ClientAuthenticationFailure
  puts "[.] auth failed"
  if cfg['auto_register']
    if Jabber::Simple.respond_to?(:register)
      im = Jabber::Simple.register(cfg['jid'], cfg['pass'])
      puts "[.] registered successfully!"
    else
      im = old_register cfg
    end
  end
  exit 1 unless im
end

if cfg['auto_add']
  # Send an authorization request to a user:
  cfg['allow'].each do |jid|
    im.add(jid)
  end
end

lastup=Time.now-5*60-1

#ENV['TERM']='xterm'

#shell=IO::popen('/bin/sh','r+')
#shell.puts 'export TERM=dumb'

# each user has his own shell
shells={}

#$STDERR=$STDOUT

loop do
	im.received_messages { |msg| 
		unless msg.type==:chat
			puts "[?] msg type is '#{msg.type}', ignoring"
			next
		end

		unless msg.x.nil?
			puts "[?] ignoring offline msg (x=#{msg.x})"
			next
		end

		unless cfg['allow'].include?(msg.from.strip.to_s)
			puts "[?] msgs not allowed from #{msg.from}"
			next
		end

		shell=shells[msg.from]

		if shell.nil? || shell[0].closed?
			shell=IO::popen('/bin/sh 2>&1','r+')
#			puts "** pid of shell = #{shell.pid}"

			Process.setpgid(shell.pid,0) rescue RuntimeError

			shells[msg.from]=[shell,
				thread=Thread.new(im, msg.from, shell){ |im, rcpt, shell|
					while !shell.closed?
						r=shell.readline
						r+=shell.read_nonblock 15000 rescue Errno::EAGAIN
						r=r.gsub /[\x01-\x08\x0b\x0c\x0e-\x1f]/,'.'
						im.deliver rcpt, r
						puts "> #{r}" if cfg['show']
					end rescue IOError
				}]
		else
			shell,thread=shell
		end

		puts "< #{msg.body}" if cfg['show']
		if msg.body[0..1]=='//'
			case msg.body[2..20]
				when 'kill'
#					puts "killing.."
					Process.kill -3, shell.pid
					sleep 0.5
					Process.kill -9, shell.pid
					thread.kill
#					puts "closing.."
					shell.close
#					puts "alive? = #{thread.alive?}"
					im.deliver msg.from, "** shell restarted"
				when 'help'
					commands = {}
					commands[:kill] = 'restart shell'
					commands[:ping] = 'simple ping'
					commands[:version] = 'show my version'
					commands[:quit] = 'quit'
					im.deliver msg.from, "** commands:\n#{commands.map{ |cmd,desc| "#{cmd} - #{desc}" }.join("\n")}"
				when 'ping'
					im.deliver msg.from, "** PONG!"
				when 'quit'
					exit
				when 'version'
					im.deliver msg.from, "** shell2jabber v#{VERSION}"
				else
					im.deliver msg.from, "** unknown command"
			end
		else
			shell.puts msg.body rescue Errno::EPIPE
		end
	}
	sleep 1
	if (Time.now-lastup).abs > 5*60
		im.status nil, `uptime`.sub(/.* (\d+) users?/,'\1 us').sub(/load averages?/,'la').strip
		lastup=Time.now
	end
end

puts "exiting.."
sleep 10
