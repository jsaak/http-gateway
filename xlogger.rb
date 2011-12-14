require 'singleton'

class LoggerSingleton
   include Singleton

   def initialize
   end

   def start(filename,dateformat,usec)
      @dateformat = dateformat
      @usec = usec
      @logfile = File.new(filename,'a')
      @logfile << "-------------------------\n"
      #log(self,'start','starting')
   end

   def log(cl, methodname, x, endline)
      t = Time.now
      sdate = t.strftime(@dateformat)
      if @usec
         sdate += '.' + '%.6d' % t.usec
      end
      #sdate = Time.now.strftime(@dateformat)
      sclass = "%16s" % cl.class.to_s
      string = "#{sdate} #{sclass}::#{methodname} #{x}"
      append(string,endline)
   end

   def append(str,endline = true)
      STDOUT.write(str)
      STDOUT.write("\n") if endline
      STDOUT.flush
      @logfile << str
      @logfile << "\n" if endline
      @logfile.flush
   end
end

module XLogger
   def xlog(x='',endline = true)
      methodname = caller[0][/`([^']*)'/, 1]

      if x.kind_of?(Exception) then
         logthis = x.backtrace[0] + ': ' + x.message + ' (' + x.class.to_s + ')'
         logthis += "\n"
         x.backtrace[1..-1].each do |bt|
            logthis += '    from ' + bt + "\n"
         end
      else
         logthis = x
      end

      LoggerSingleton.instance.log(self, methodname, logthis, endline)
   end

   def xlog_start(filename,dateformat = '%Y.%m.%d %H:%M:%S',usec = false)
      if dateformat.nil?
         dateformat = '%Y.%m.%d %H:%M:%S'
      end
      LoggerSingleton.instance.start(filename, dateformat, usec)
   end

   def xlog_ne(x)
      methodname = caller[0][/`([^']*)'/, 1]
      LoggerSingleton.instance.log(self, methodname, x, false)
   end

   def xlog_append(x)
      LoggerSingleton.instance.append(x,false)
   end
end
