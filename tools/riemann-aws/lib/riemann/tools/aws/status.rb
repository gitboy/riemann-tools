# frozen_string_literal: true

require 'riemann/tools'

module Riemann
  module Tools
    module Aws
      class Status
        include Riemann::Tools
        require 'fog/aws'
        require 'date'

        opt :fog_credentials_file, 'Fog credentials file', type: String
        opt :fog_credential, 'Fog credentials to use', type: String
        opt :access_key, 'AWS access key', type: String
        opt :secret_key, 'Secret access key', type: String
        opt :region, 'AWS region', type: String, default: 'eu-west-1'

        opt :retirement_critical, 'Number of days before retirement. Defaults to 2', default: 2
        opt :event_warning, 'Number of days before event. Defaults to nil (i.e. when the event appears)', default: nil

        def initialize
          if options[:fog_credentials_file]
            Fog.credentials_path = options[:fog_credentials_file]
            Fog.credential = options[:fog_credential].to_sym
            @compute = Fog::AWS::Compute.new
          else
            @compute = if options[:access_key] && options[:secret_key]
                         Fog::AWS::Compute.new({
                                                 access_key_key_id: options[:access_key],
                                                 secret_key_access_key: options[:secret_key],
                                                 region: options[:region],
                                               })
                       else
                         Fog::AWS::Compute.new({
                                                 use_iam_profile: true,
                                                 region: options[:region],
                                               })
                       end
          end
        end

        def tick
          hosts = @compute.servers.select { |s| s.state == 'running' }

          hosts.each do |host, host_status|
            host_status['eventsSet'].each do |event|
              before, _after = %w[notBefore notAfter].map { |k| Date.parse event[k].to_s if event[k] }

              ev = {
                host: host,
                service: 'aws_instance_status',
                description: "#{event['code']}\n\nstart #{event['notBefore']}\nend #{event['notAfter']}\n\n#{event['description']}",
                state: 'ok',
                ttl: 300,
              }

              ev2 = if (event['code'] == 'instance-retirement') &&
                       (Date.today >= before - opts[:retirement_critical])
                      { state: 'critical' }
                    elsif opts[:event_warning] && (Date.today >= before - opts[:event_warning])
                      { state: 'warning' }
                    else
                      {}
                    end

              report ev.merge(ev2)
            end
          end
        end
      end
    end
  end
end
