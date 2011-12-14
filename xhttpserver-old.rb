require 'socket'
require 'xlogger'

class Request
   attr_accessor :type
   attr_reader :raw_header
   attr_reader :raw_body
   attr_reader :raw_preheader
   attr_reader :error
   
   def initialize
      @h = Hash.new
      @valid = true
   end

   def set_header(str)
      @raw_header = str

      x = str.split("\r\n")
      x.each do |line|
         hn, hv = line.split /:\s*/
         hn.downcase!
         @h[hn] = hv
      end
   end

   def set_body(str)
      @raw_body = str
   end

   def set_preheader(str)
      @raw_preheader = str
   end

   def set_error(str)
      @valid = false
      @error = str
   end

   def raw
      s = ''
      unless @raw_preheader.nil?
         s += @raw_preheader
      end

      unless @raw_header.nil?
         s += @raw_header
      end

      unless @raw_body.nil?
         s += "\r\n"
         s += @raw_body
      end
      
      return s
   end

   def headers
      return @h
   end

   def valid?
      return @valid
   end

   def invalid?
      return (!@valid)
   end
end

class XHttpServer
   include XLogger
   include Socket::Constants

   def ok(sock,str)
      answer('HTTP/1.1 200 OK',sock,str,['Content-Type: text/html; charset=utf-8'])
   end

   def error(sock,str)
      answer('HTTP/1.1 500 Internal Server Error',sock,str,['Content-Type: text/html; charset=utf-8'])
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
      r = accept_http(s)
      s.close
      return r
   end

   def accept_http(client)
      req = Request.new
      state = :preheader
      chunked = false
      raw_header = ''
      raw_body = ''
      content_length = nil
      begin
         while true
            buffer = ''
            loop do
               begin
                  buffer += client.read_nonblock(60000)
               rescue Errno::EAGAIN
                  sleep(0.25)
                  retry
               rescue Errno::ECONNRESET
                  return nil
               rescue EOFError
                  return nil
               end
               break if buffer.include?("\r\n\r\n")
            end

            firstpart,secondpart = buffer.split("\r\n\r\n")
            lines = firstpart.split("\r\n")
            preheader = lines[0]
            req.set_preheader(preheader)
            headers = lines[1..-1]
            req.set_header(headers.join("\r\n"))

            #preheader
            if preheader =~ /^GET/
               req.type = 'GET'
            elsif preheader =~ /^POST/
               req.type = 'POST'
            elsif preheader =~ /^PUT/
               req.type = 'PUT'
            else
               req.type = 'ANSWER'
            end
            
            #header
            headers.each do |header|
               x = header.split(/^[Cc]ontent-[Ll]ength:\s*/)
               if x.size == 2
                  content_length = x[1].to_i
                  #puts "content length: #{content_length}"
               end
               if header =~ /^[Tt]ransfer-[Ee]ncoding:\s*[Cchunked]/
                  chunked = true
               end
            end

            #body if needed
            if req.type == 'GET'
               return req
            elsif req.type == 'POST' or req.type == 'ANSWER'
               if chunked
                  req.set_error('Transfer-Encoding: chunked not implemented')
                  return req
               end
               if content_length.nil?
                  req.set_error('no Content-Length found')
                  return req
               end

               #read body
               if secondpart.nil?
                  xlog 'secondpart = nil'
                  return req if content_length == 0

                  secondpart = ''
                  loop do
                     begin
                        secondpart += client.read_nonblock(content_length - secondpart.size)
                     rescue Errno::EAGAIN
                        sleep(0.25)
                        retry
                     rescue Errno::ECONNRESET
                        req.set_error('Incomplete HTTP request: connection reset by peer')
                        return req
                     end
                     break if secondpart.size >= content_length
                  end
                  body = secondpart
               elsif secondpart.size == content_length
                  xlog "secondpart.size(#{secondpart.size}) == content_length(#{content_length})"
                  body = secondpart
               elsif secondpart.size < content_length
                  xlog "secondpart.size(#{secondpart.size}) < content_length(#{content_length})"
                  loop do
                     begin
                        secondpart += client.read_nonblock(content_length - secondpart.size)
                     rescue Errno::EAGAIN
                        sleep(0.25)
                        retry
                     end
                     break if secondpart.size >= content_length
                  end
                  body = secondpart
               elsif secondpart.size > content_length
                  xlog "secondpart.size(#{secondpart.size}) > content_length(#{content_length})"
                  body = secondpart[1..content_length]
               end
               req.set_body(body)
               return req
            else
               req.set_error('PUT not implemented')
               return req
            end
         end
      rescue => e
         req.set_error(e.to_s)
         xlog e
         #raise
         return req
      end
   end

   def start(port,bind_address = '0.0.0.0',&block)
      @socket = Socket.new(AF_INET, SOCK_STREAM, 0)
      sockaddr = Socket.pack_sockaddr_in(port, bind_address)
      xlog_ne "waiting for port #{port}"
      begin
         @socket.bind(sockaddr)
      rescue Errno::EADDRINUSE => e
         xlog_append '.'
         sleep(2)
         retry
      end
      xlog_append "\n"
      @socket.listen( 5 )
      @stopped = false
      xlog "listening on #{port}"

      @thread = Thread.new do
         while @stopped == false
            begin
               client, client_sockaddr = @socket.accept
            rescue IOError => e
               xlog "closing port #{port}"
               break
            end
            xlog 'accept' if $DEBUG
            t = Thread.new do
               socket_alive = true
               while @stopped == false
                  req = accept_http(client)

                  if req.nil?
                     client.close
                     break
                  else
                     block.call(req,client)
                  end
               end
            end
            t.join
            t.abort_on_exception=true
         end
      end
   end

   def stop
      @stopped = true
      @socket.close
   end

   def join
      @thread.join
   end

   def thread
      @thread
   end
end
