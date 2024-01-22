# frozen_string_literal: true

require 'riemann/tools'

module Riemann
  module Tools
    module Aws
      class S3Status
        include Riemann::Tools
        require 'fog/aws'
        require 'time'

        opt :fog_credentials_file, 'Fog credentials file', type: String
        opt :fog_credential, 'Fog credentials to use', type: String
        opt :access_key, 'AWS Access Key', type: String
        opt :secret_key, 'AWS Secret Key', type: String
        opt :region, 'AWS Region', type: String, default: 'eu-west-1'
        opt :buckets, 'Buckets to pull metrics from, multi=true', type: String, multi: true, required: true
        opt :statistic, 'Statistic to retrieve, multi=true, e.g. --statistic=Average --statistic=Maximum', type: String,
                                                                                                           multi: true, required: true

        def base_metrics
          # get last 60 seconds
          start_time = (Time.now.utc - (3600 * 24 * 1)).iso8601
          end_time = Time.now.utc.iso8601

          # The base query that all metrics would get
          {
            'Namespace'  => 'AWS/S3',
            'StartTime'  => start_time,
            'EndTime'    => end_time,
            'Period'     => 3600,
            'MetricName' => 'NumberOfObjects',
          }
        end

        def tick
          if options[:fog_credentials_file]
            Fog.credentials_path = options[:fog_credentials_file]
            Fog.credential = options[:fog_credential].to_sym
            connection = Fog::AWS::CloudWatch.new
          else
            connection = if options[:access_key] && options[:secret_key]
                           Fog::AWS::CloudWatch.new({
                                                      aws_access_key_id: options[:access_key],
                                                      aws_secret_access_key: options[:secret_key],
                                                      region: options[:region],
                                                    })
                         else
                           Fog::AWS::CloudWatch.new({
                                                      use_iam_profile: true,
                                                      region: options[:region],
                                                    })
                         end
          end

          options[:statistic].each do |statistic|
            options[:buckets].each do |bucket|
              metric_base_options = base_metrics
              metric_base_options['Statistics'] = statistic
              metric_base_options['Dimensions'] = [
                { 'Name' => 'BucketName', 'Value' => bucket },
                { 'Name' => 'StorageType', 'Value' => 'AllStorageTypes' },
              ]

              result = connection.get_metric_statistics(metric_base_options)
              next if result.body['GetMetricStatisticsResult']['Datapoints'].empty?

              result.body['GetMetricStatisticsResult']['Datapoints'][0].keys.sort.each do |stat_type|
                next if stat_type == 'Unit'
                next if stat_type == 'Timestamp'

                unit = result.body['GetMetricStatisticsResult']['Datapoints'][0]['Unit']
                metric = result.body['GetMetricStatisticsResult']['Datapoints'][0][stat_type]
                event = event(bucket, result.body['GetMetricStatisticsResult']['Label'], stat_type, unit, metric)
                report(event)
              end
            end
          end
        end

        private

        def event(bucket, label, metric_type, stat_type, metric, unit = nil)
          {
            host: "bucket_#{bucket}",
            service: "s3.#{label}.#{metric_type}.#{stat_type}",
            ttl: 300,
            description: "#{bucket} #{metric_type} #{stat_type} (#{unit})",
            tags: ['s3_metrics'],
            metric: metric,
          }
        end
      end
    end
  end
end
