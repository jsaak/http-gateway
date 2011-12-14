#!/usr/bin/ruby

# idea and some code stolen from:
# John Mettraux at openwfe.org

require 'thread'

class SchedulerJob
   attr_accessor :time
   attr_accessor :block

   def initialize(time,block)
      @time = time
      @block = block
   end
end

class Scheduler
   def initialize
      @jobs = Array.new

      @precision = 0.250
      @stopped = true

      @add_queue = Queue.new
      @remove_queue = Queue.new

      @job_id_mutex = Mutex.new
      @job_id = 0
   end

   def stop
      @stopped = true
   end

   def add_job(time = Time.now,&block)
      j = SchedulerJob.new(time,block)
      @add_queue << j
      return j
   end

   def delete_job(j)
      @remove_queue << j
   end

   def clear
      @jobs.each do |j|
         @remove_queue << j
      end
   end

   def join
      @scheduler_thread.join
   end

   def start
      @stopped = false
      @scheduler_thread = Thread.new do
         Thread.current[:name] = @thread_name
         @remove = Array.new
         loop do
            break if @stopped
            t0 = Time.now.to_f

            #remove
            loop do
               break if @remove_queue.empty?
               j = @remove_queue.pop
               @jobs.delete(j)
            end

            #do
            @jobs.each do |j|
               next if j.nil?
               next if j.time > Time.now
               j.block.call
               @remove_queue << j
            end

            #add
            loop do
               break if @add_queue.empty?
               j = @add_queue.pop
               @jobs.push(j)
            end

            #wait if there is enough time
            d = Time.now.to_f - t0
            next if d > @precision
            sleep (@precision - d)
         end
      end
   end
end
