#!/usr/bin/ruby

require 'socket'

begin
   @port = 12345
   @bind_address = "127.0.0.1"

   # server 
   @ls = Socket.new( Socket::AF_INET, Socket::SOCK_STREAM, 0 )
   sockaddr = Socket.pack_sockaddr_in( @port, @bind_address )
   print "waiting for port #{@port}"
   begin
      @ls.bind(sockaddr)
   rescue Errno::EADDRINUSE => e
      print '.'
      STDOUT.flush
      sleep(1)
      retry
   end
   print "\n"
   @ls.listen(5)
   puts "listening on #{@port}"

   #client connects
   cs = Socket.new( Socket::AF_INET, Socket::SOCK_STREAM, 0 )
   cs.connect(sockaddr)

   # server accepts
   ss,ss_addr = @ls.accept()
   puts "accepted #{ss}"

   # server close
   puts "ss.close"
   ss.close

   # client reads
   ret = select([cs],[],[cs],0)
   r,w,e = ret
   puts "select read #{r}"
   puts "select write #{w}"
   puts "select error #{e}"
   #begin
      #tmp = r[0].read_nonblock(10)
   #rescue EOFError
      #puts "EOF"
   #end

   sleep(10)

   # client close
   puts "cs.close"
   cs.close
end
