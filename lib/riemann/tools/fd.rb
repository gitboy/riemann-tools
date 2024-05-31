# frozen_string_literal: true

require 'riemann/tools'

# Reports current file descriptor use to riemann.
# By default reports the total system fd usage, can also report usage of individual processes
module Riemann
  module Tools
    class Fd
      include Riemann::Tools

      opt :fd_sys_warning, 'open file descriptor threshold for system', default: 800
      opt :fd_sys_critical, 'open file descriptor critical threshold for system', default: 900
      opt :fd_proc_warning, 'open file descriptor threshold for process', default: 800
      opt :fd_proc_critical, 'open file descriptor critical threshold for process', default: 900
      opt :processes, 'list of processes to measure fd usage in addition to system total', type: :ints

      def initialize
        super

        @limits = {
          fd: { critical: opts[:fd_sys_critical], warning: opts[:fd_sys_warning] },
          process: { critical: opts[:fd_proc_critical], warning: opts[:fd_proc_warning] },
        }
        ostype = `uname -s`.chomp.downcase
        case ostype
        when 'freebsd'
          @fd = method :freebsd_fd
        else
          puts "WARNING: OS '#{ostype}' not explicitly supported. Falling back to Linux" unless ostype == 'linux'
          @fd = method :linux_fd
        end
      end

      def alert(service, state, metric, description)
        report(
          service: service.to_s,
          state: state.to_s,
          metric: metric.to_f,
          description: description,
        )
      end

      def freebsd_fd
        sys_used = Integer(`sysctl -n kern.openfiles`)
        if sys_used > @limits[:fd][:critical]
          alert 'fd sys', :critical, sys_used, "system is using #{sys_used} fds"
        elsif sys_used > @limits[:fd][:warning]
          alert 'fd sys', :warning, sys_used, "system is using #{sys_used} fds"
        else
          alert 'fd sys', :ok, sys_used, "system is using #{sys_used} fds"
        end
      end

      def linux_fd
        sys_used = Integer(`lsof | wc -l`)
        if sys_used > @limits[:fd][:critical]
          alert 'fd sys', :critical, sys_used, "system is using #{sys_used} fds"
        elsif sys_used > @limits[:fd][:warning]
          alert 'fd sys', :warning, sys_used, "system is using #{sys_used} fds"
        else
          alert 'fd sys', :ok, sys_used, "system is using #{sys_used} fds"
        end

        opts[:processes]&.each do |process|
          used = Integer(`lsof -p #{process} | wc -l`)
          name, _pid = `ps axo comm,pid | grep -w #{process}`.split
          if used > @limits[:process][:critical]
            alert "fd #{name} #{process}", :critical, used, "process #{name} #{process} is using #{used} fds"
          elsif used > @limits[:process][:warning]
            alert "fd #{name} #{process}", :warning, used, "process #{name} #{process} is using #{used} fds"
          else
            alert "fd #{name} #{process}", :ok, used, "process #{name} #{process} is using #{used} fds"
          end
        end
      end

      def tick
        @fd.call
      end
    end
  end
end
