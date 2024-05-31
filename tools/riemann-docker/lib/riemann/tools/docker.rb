# frozen_string_literal: true

require 'riemann/tools'

# Reports current CPU, disk, load average, and memory use to riemann.
module Riemann
  module Tools
    class Docker
      require 'docker'
      require 'socket'
      include Riemann::Tools
      include ::Docker

      opt :docker_host, 'Docker Container Host (see https://github.com/swipely/docker-api#host)', type: String,
                                                                                                  default: nil
      opt :cpu_warning, 'CPU warning threshold (fraction of total jiffies)', default: 0.9
      opt :cpu_critical, 'CPU critical threshold (fraction of total jiffies)', default: 0.95
      opt :disk_warning, 'Disk warning threshold (fraction of space used)', default: 0.9
      opt :disk_critical, 'Disk critical threshold (fraction of space used)', default: 0.95
      opt :memory_warning, 'Memory warning threshold (fraction of RAM)', default: 0.85
      opt :memory_critical, 'Memory critical threshold (fraction of RAM)', default: 0.95
      opt :host_hostname, 'Suffix of host', type: String, default: nil
      opt :checks, 'A list of checks to run.', type: :strings, default: %w[cpu memory disk basic]

      def containers
        Docker::Container.all
      end

      def get_container_name(container)
        container.json['Name'][1..]
      end

      def initialize
        super

        Docker.url = opts[:docker_host] unless opts[:docker_host].nil?

        @hostname = opts[:host_hostname]
        @hostname = Socket.gethostname if @hostname.nil? || !(@hostname.is_a? String) || @hostname.empty?

        @cpu_coefficient = 1000 * 1000 * 1000

        @limits = {
          cpu: { critical: opts[:cpu_critical], warning: opts[:cpu_warning] },
          disk: { critical: opts[:disk_critical], warning: opts[:disk_warning] },
          memory: { critical: opts[:memory_critical], warning: opts[:memory_warning] },
        }

        @last_cpu_reads = {}
        @last_uptime_reads = {}

        opts[:checks].each do |check|
          case check
          when 'disk'
            @disk_enabled = true
          when 'cpu'
            @cpu_enabled = true
          when 'memory'
            @memory_enabled = true
          when 'basic'
            @basic_inspection_enabled = true
          end
        end
      end

      def alert(container, service, state, metric, description)
        opts = {
          service: service.to_s,
          state: state.to_s,
          metric: metric.to_f,
          description: description,
        }

        opts[:host] = if !container.nil?
                        "#{@hostname}-#{container}"
                      else
                        @hostname
                      end

        report(opts)
      end

      def report_pct(container, service, fraction, report = '', name = nil)
        return unless fraction

        name = service if name.nil?

        if fraction > @limits[service][:critical]
          alert container, name, :critical, fraction, "#{format('%.2f', fraction * 100)}% #{report}"
        elsif fraction > @limits[service][:warning]
          alert container, name, :warning, fraction, "#{format('%.2f', fraction * 100)}% #{report}"
        else
          alert container, name, :ok, fraction, "#{format('%.2f', fraction * 100)}% #{report}"
        end
      end

      def cpu(id, name, stats)
        current = stats['precpu_stats']['cpu_usage']['total_usage'] / stats['precpu_stats']['cpu_usage']['percpu_usage'].count

        unless current
          alert name, :cpu, :unknown, nil, 'no total usage found in docker remote api stats'
          return false
        end

        current_time = Time.parse(stats['read'])
        unless @last_cpu_reads[id].nil?
          last = @last_cpu_reads[id]
          used = (current - last[:v]) / (current_time - last[:t]) / @cpu_coefficient

          report_pct name, :cpu, used
        end

        @last_cpu_reads[id] = { v: current, t: current_time }
      end

      def memory(_id, name, stats)
        memory_stats = stats['memory_stats']
        usage = memory_stats['usage'].to_f
        total = memory_stats['limit'].to_f
        fraction = (usage / total)

        report_pct name, :memory, fraction, "#{usage} / #{total}"
      end

      def disk
        `df -P`.split("\n").each do |r|
          f = r.split(/\s+/)
          next if f[0] == 'Filesystem'
          next unless f[0] =~ %r{/} # Needs at least one slash in the mount path

          # Calculate capacity
          x = f[4].to_f / 100
          report_pct(nil, :disk, x, "#{f[3].to_i / 1024} mb left", "disk #{f[5]}")
        end
      end

      def basic_inspection(id, name, inspection)
        state = inspection['State']
        json_state = JSON.generate(state)

        running = state['Running']

        alert(
          name, 'status',
          running ? 'ok' : 'critical',
          running ? 1 : 0,
          json_state,
        )

        return unless running

        start_time = DateTime.rfc3339(state['StartedAt']).to_time.utc.to_i
        now = DateTime.now.to_time.utc.to_i
        uptime = now - start_time

        unless @last_uptime_reads[id].nil?
          last = @last_uptime_reads[id]
          restarted = start_time != last
          alert(
            name, 'uptime',
            restarted ? 'critical' : 'ok',
            uptime,
            "last 'StartedAt' measure was #{last} (#{Time.at(last).utc}), " \
            "now it's #{start_time} (#{Time.at(start_time).utc})",
          )
        end

        @last_uptime_reads[id] = start_time
      end

      def tick
        # Disk is the same in every container
        disk if @disk_enabled

        # Get CPU, Memory and Load of each container
        threads = containers.map do |ctr|
          Thread.new(ctr) do |container|
            id = container.id
            name = get_container_name(container)

            stats = Docker::Util.parse_json(container.connection.get("/containers/#{id}/stats", { stream: false }))

            if @basic_inspection_enabled
              inspection = Docker::Util.parse_json(container.connection.get("/containers/#{id}/json"))
              basic_inspection(id, name, inspection)
            end
            cpu(id, name, stats) if @cpu_enabled
            memory(id, name, stats) if @memory_enabled
          end
        end

        threads.each do |thread|
          thread.join
        rescue StandardError => e
          warn "#{e.class} #{e}\n#{e.backtrace.join "\n"}"
        end
      end
    end
  end
end
