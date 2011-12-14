#!/usr/bin/ruby

require 'socket'

include Socket::Constants

message = "POST HTTP/1.1\r\nContent-Type: application/x-www-form-urlencoded;charset=utf-8\r\nHost: 195.70.36.170:16843\r\nContent-Length: 278\r\n\r\nusername=andris%40napalm.hu&password=NDX5192&account=EX0045232&notificationType=MessageReceived&id=41fcbb35-03b4-4789-9b1f-d17aec9c1ce3&originator=36302112666&recipient=447800009672&body=Mac.test+37&type=Text&sentAt=2008-09-15+13%3a01%3a49Z&receivedAt=2008-09-15+13%3a01%3a49Z\r\n"

@socket = Socket.new( AF_INET, SOCK_STREAM, 0 )
sockaddr = Socket.pack_sockaddr_in( 16843, 'localhost' )
p @socket.connect(sockaddr)
p @socket.write(message)
puts message
p @socket.close
