#!/usr/bin/ruby

if ARGV[0].nil?
   puts "usage: #{__FILE__} config.cfg.rb"
   exit 1
end

require ARGV[0]
require 'xhttpserver'
require 'xlogger'
require 'xscheduler'

module Common
   include XLogger

   def hex_encode(str)
      if str.nil?
         ''
      else
         str.unpack('H*')[0]
      end
   end

   def hex_decode(str)
      [str].pack('H*')
   end

   def error(c,s)
      xlog s
      XHttpServer.new.error(c,s)
   end
end

class Session
   include Socket::Constants
   include Common

   @@id_seq = 0

   attr_reader :id
   attr_accessor :scheduler_job

   def initialize
      #TODO multithread?
      @@id_seq += 1

      alphabet = '0123456789qwertzuiopasdfghjklyxcvbnmQWERTZUIOPASDFGHJKLYXCVBNM'
      randstring = @@id_seq.to_s + '-'
      10.times do
         x = rand(alphabet.size)
         randstring = randstring + alphabet[x..x]
      end

      @id = randstring
   end

   def connect(host,port)
      @casino_socket = Socket.new( AF_INET, SOCK_STREAM, 0 )
      sockaddr = Socket.pack_sockaddr_in(port,host)
      begin
         @casino_socket.connect(sockaddr)
         return true
      rescue => e
         xlog "casino server is not running on #{host}:#{port}"
         xlog e
         return false
      end
   end

   def communicate(client,to_server)
      xlog @id.to_s + ' S<-C: ' + hex_encode(to_server)
      @casino_socket.write(to_server)
      sleep(0.1)
      #xlog @id.to_s + ' read_start'
      begin
         buff = @casino_socket.read_nonblock(65000)
      rescue Errno::EAGAIN
         #xlog @id.to_s + ' nothing to read'
      rescue EOFError => e
         xlog @id.to_s + ' session disconnected'
         xlog @id.to_s + ' ' + e
         error(client,'Session disconnected')
         disconnect
         return :disconnected
      end

      t = Time.now
      t_str = t.strftime('%H:%M:%S.')
      t_str += '%.6d' % t.usec

      if buff.nil?
         xlog @id.to_s + " S->C: nil"
         XHttpServer.new.answer('HTTP/1.1 200 OK',client,'',
                            ["Session-id: #{@id}",
                             'Content-type: application/binary',
                             "Date: #{t_str}"])
         return :ok
      elsif buff.length == 65000
         throw 'Gigantic packet from casino server'
      else
         xlog @id.to_s + " S->C: " + hex_encode(buff)
         XHttpServer.new.answer('HTTP/1.1 200 OK',client,buff,["Session-id: #{@id}",'Content-type: application/binary',"Date: #{t_str}"])
         return :ok
      end
   end

   def disconnect
      @casino_socket.close
   end
end

class App
   include Common

   def initialize
      @sessions = Hash.new
      @sched = Scheduler.new
   end

   def comm(session_id,client,body)
      s = @sessions[session_id]
      # delete old job, add a new job
      @sched.delete_job(s.scheduler_job)
      s.scheduler_job = @sched.add_job(Time.now + 600) do
         @sessions[session_id].disconnect
         @sessions.delete(session_id)
         xlog "timeout session_id: #{session_id}"
      end

      # comm
      status = s.communicate(client,body)
      if status == :disconnected
         #@sessions[session_id].disconnect
         @sched.delete_job(s.scheduler_job)
         @sessions.delete(session_id)
      end
   end

   def run
      xlog_start(Cfg::LOG_FILENAME,nil,true)
      @sched.start
      @s = XHttpServer.new
      @s.start(Cfg::LISTENER_PORT,Cfg::LISTENER_HOST) do |req,client|
         xlog 'new request: '
         xlog req.raw

         #xlog req.raw_preheader
         #xlog req.raw_header
         #xlog req.raw_body
         #xlog hex_encode(req.raw_body)
         #xlog '**************************************'

         #if req.invalid?
            #error(client,req.error)
            #xlog req.error
            #xlog req.raw_preheader
            #xlog req.raw_header
            #next
         #end

         if req.type == 'GET'
            if req.raw_preheader =~ /test.html/
               xlog 'service running'
               @s.ok(client,'service running')
            else
               @s.not_found(client,'get lost')
               xlog 'get_lost'
            end
            @s.remove(client)
            next
         end

         if req.raw_preheader =~ /demo.html/
            code = 'D'
         elsif req.raw_preheader =~ /fun.html/
            code = 'F'
         elsif req.raw_preheader =~ /normal.html/
            code = 'N'
         elsif req.raw_preheader =~ /close.html/
            code = 'C'
         else
            error(client,"Unknown url: #{req.raw_preheader}")
            next
         end

         session_id = req.headers['session-id']
         #if not session_id.nil?
            #session_id = session_id.to_i
         #end

         body = req.raw_body

         if code == 'F' or code == 'D'
            #open
            if code == 'F'
               host = Cfg::FUN_HOST
               port = Cfg::FUN_PORT
            elsif code == 'D'
               host = Cfg::DEMO_HOST
               port = Cfg::DEMO_PORT
            end

            s = Session.new
            @sessions[s.id] = s
            connected = s.connect(host,port)
            if not connected
               error(client,"Casino server is not responding on #{host}:#{port}")
            else
               session_id = s.id
               comm(session_id,client,body)
            end
         elsif code == 'N'
            #normal
            if session_id.nil?
               error(client,'Session-Id HTTP header not found')
            else
               if @sessions[session_id].nil?
                  error(client,"Invalid session: #{session_id}")
               else
                  comm(session_id,client,body)
               end
            end
         elsif code == 'C'
            #close
            if session_id.nil?
               error(client,'Session-Id HTTP header not found')
            else
               if @sessions[session_id].nil?
                  error(client,"Invalid session: #{session_id}")
               else
                  comm(session_id,client,body)
                  unless @sessions[session_id].nil?
                     @sessions[session_id].disconnect
                     @sessions.delete(session_id)
                  end
               end
            end
         else
            raise 'unknown code:' + code
         end
      end

      trap(:INT) do
         @s.stop
      end

      @s.join
   end
end

a = App.new
a.run
