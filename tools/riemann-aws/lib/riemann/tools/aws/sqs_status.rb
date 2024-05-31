# frozen_string_literal: true

require 'riemann/tools'

module Riemann
  module Tools
    module Aws
      class SqsStatus
        include Riemann::Tools
        require 'fog/aws'

        opt :access_key, 'AWS access key', type: String
        opt :secret_key, 'Secret access key', type: String
        opt :region, 'AWS region', type: String, default: 'us-east-1'
        opt :queue, 'SQS Queue name', type: String
        def initialize
          super

          creds = if opts.key?('access_key') && opts.key?('secret_key')
                    {
                      aws_access_key_id: opts[:access_key],
                      aws_secret_access_key: opts[:secret_key],
                    }
                  else
                    { use_iam_profile: true }
                  end
          creds['region'] = opts[:region]
          @sqs = Fog::AWS::SQS.new(creds)
          response = @sqs.list_queues({ 'QueueNamePrefix' => opts[:queue] })
          @queue_url = response[:body]['QueueUrls'].first
        end

        def tick
          response = @sqs.get_queue_attributes(@queue_url, 'All')
          %w[ApproximateNumberOfMessages ApproximateNumberOfMessagesNotVisible].each do |attr|
            msg = {
              metric: response[:body]['Attributes'][attr],
              service: "#{opts[:queue]} #{attr}",
              state: 'ok',
            }
            report msg
          end
        end
      end
    end
  end
end
