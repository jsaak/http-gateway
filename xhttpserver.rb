#!/usr/bin/ruby

require 'socket'
require 'stringio'
require 'xlogger'

class XHttpServer
   include Socket::Constants
   include XLogger

   def start(port,bind_address = '0.0.0.0',&block)
      @port = port
      @bind_address = bind_address
      @block = block

      @socket = Socket.new( AF_INET, SOCK_STREAM, 0 )
      sockaddr = Socket.pack_sockaddr_in( @port, @bind_address )
      xlog_ne "waiting for port #{@port}"
      begin
         @socket.bind(sockaddr)
      rescue Errno::EADDRINUSE => e
         xlog_append '.'
         sleep(1)
         retry
      end
      xlog_append "\n"
      @socket.listen( 5 )
      xlog "listening on #{@port}"

      @run = true

      @cr = Array.new
      @parsers = Hash.new
      while @run
         ret = select([@socket]+@cr,[],[])
         r,w,e = ret
         r.each do |fd|
            if fd == @socket
               client, client_sockaddr = @socket.accept
               @cr.push(client)
               @parsers[client] = XHttpParser.new(client,@block)
               port, host = Socket.unpack_sockaddr_in(client_sockaddr)
               xlog "#{client} new connection from #{host}:#{port}"
            else
               begin
                  r = fd.read_nonblock(10000)
                  @parsers[fd] << r
               rescue EOFError
                  xlog "#{fd} EOF"
                  remove(fd)
               rescue Errno::ECONNRESET => e
                  xlog "#{fd} ECONNRESET"
                  remove(fd)
               rescue InvalidRequest => e
                  xlog "#{fd} #{e}"
                  error(fd,'Invalid Request')
                  remove(fd)
               rescue => e
                  xlog "#{fd} #{e}"
                  remove(fd)
               end
            end
         end
      end
   end

   def remove(fd)
      begin
         fd.close
      rescue Exception => e
         xlog e
      end
      @cr.delete(fd)
      @parsers.delete(fd)
   end

   def ok(sock,str)
      answer('HTTP/1.1 200 OK',sock,str,['Content-Type: text/plain; charset=utf-8'])
   end

   def error(sock,str)
      answer('HTTP/1.1 500 Internal Server Error',sock,str,['Content-Type: text/plain; charset=utf-8'])
   end

   def not_found(sock,str)
      answer('HTTP/1.1 404 Not Found',sock,str,['Content-Type: text/plain; charset=utf-8','Connection: close'])
   end

   def answer(type,sock,str,headers = [])
      content = str
      response = ''
      response += type
      response += "\r\n"
      response += 'Content-Length: ' + content.length.to_s
      response += "\r\n"

      headers.each do |h|
         response += h
         response += "\r\n"
      end

      response += "\r\n"
      response += content
      response += "\r\n"
      #puts response
      #puts '*******************'
      begin
         sock.write_nonblock(response)
      rescue Errno::ECONNRESET => e
         xlog e
      rescue IOError => e
         xlog e
      rescue Exception => e
         xlog e
      end
   end

   def test_post(port,host,header,body,url)
      req = "POST HTTP/1.1 #{url}"
      req += "\r\n"
      req += 'Content-Length: ' + body.length.to_s
      req += "\r\n"
      req += header
      req += "\r\n"
      req += body
      puts req

      s = Socket.new(AF_INET, SOCK_STREAM, 0)
      sockaddr = Socket.pack_sockaddr_in(port, host)
      s.connect(sockaddr)
      s.write(req)
      #TODO r = accept_http(s)
      s.close
      return r
   end

end

class NeedMoreData < Exception
end

class InvalidRequest < Exception
   def initialize(str)
      @str = str
   end

   def to_s
      @str
   end
end

class XHttpParser
   def initialize(client,block)
      @state = :start
      @buffer = ''
      @sio = StringIO.new('')
      @block = block
      @client = client
   end

   def getline
      pos = @sio.pos

      begin
         x = @sio.readline
      rescue EOFError
         raise NeedMoreData
      end

      if x[-1..-1] != "\n"
         @sio.seek(pos)
         raise NeedMoreData
      end

      return x.chomp
   end

   def getbytes(x)
      pos = @sio.pos
      r = @sio.read(x)

      if r.nil?
         @sio.seek(pos)
         raise NeedMoreData
      end
      if r.size != x
         @sio.seek(pos)
         raise NeedMoreData
      end
      return r
   end

   def <<(data)
      pos = @sio.pos
      @sio.seek(0,IO::SEEK_END)
      @sio.write(data)
      @sio.seek(pos)

      begin
         while true
            if @state == :start
               @req = XHttpRequest.new
               @content_length = nil

               line = getline
               if line =~ /^GET/
                  @req.type = 'GET'
               elsif line =~ /^POST/
                  @req.type = 'POST'
               else
                  raise InvalidRequest.new('Unknown HTTP method:' + line)
               end
               @req.set_preheader(line)
               @raw_header = ''
               @state = :header
            elsif @state == :header
               line = getline
               @raw_header << line << "\r\n"

               if line.size == 0
                  if @req.type == 'GET'
                     @req.set_header(@raw_header)
                     @block.call(@req,@client)
                     @state = :start
                  elsif @req.type == 'POST'
                     if @content_length.nil?
                        raise InvalidRequest.new('No Content-Length found in POST')
                     else
                        @req.set_header(@raw_header)
                        @raw_body = ''
                        @state = :body
                     end
                  end
               else
                  x = line.split(/^[Cc]ontent-[Ll]ength:\s*/)
                  if x.size == 2
                     @content_length = x[1].to_i
                     #puts "content length: #{content_length}"
                  end
                  if line =~ /^[Tt]ransfer-[Ee]ncoding:\s*[Cc]hunked/
                     raise InvalidRequest.new('Transfer-Encoding: chunked not implemented')
                  end
               end
            elsif @state == :body
               @req.set_body(getbytes(@content_length))
               @block.call(@req,@client)
               @state = :start
            end
         end
      rescue NeedMoreData
         #p 'NeedMoreData'
      end
   end
end

class XHttpRequest
   attr_accessor :type
   attr_reader :raw_header
   attr_reader :raw_body
   attr_reader :raw_preheader

   def initialize
      @h = Hash.new
   end

   def set_header(str)
      @raw_header = str

      x = str.split("\n")
      x.each do |line|
         l = line.strip
         hn, hv = l.split /:\s*/
         unless hn.nil?
            hn.downcase!
            @h[hn] = hv
         end
      end
   end

   def set_body(str)
      @raw_body = str
   end

   def set_preheader(str)
      @raw_preheader = str
   end

   def raw
      s = ''
      unless @raw_preheader.nil?
         s += @raw_preheader
         s += "\r\n"
      end

      unless @raw_header.nil?
         s += @raw_header
      end

      unless @raw_body.nil?
         if @h['content-type'] =~ /[Bb]inary/
            s += hex_encode(@raw_body)
         else
            s += @raw_body
         end
      end

      return s
   end

   def headers
      return @h
   end

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
end

#s = XHttpServer.new
#s.run(12345) do |req, client|
   #s.notfound(client,'ok')
   #p 'request'
   #p req
   #p client
#end


