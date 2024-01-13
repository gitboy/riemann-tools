# frozen_string_literal: true

require 'riemann/tools/version'
require 'bundler/gem_tasks'
require 'github_changelog_generator/task'

GitHubChangelogGenerator::RakeTask.new :changelog do |config|
  config.user = 'riemann'
  config.project = 'riemann-tools'
  config.exclude_labels = %w[dependencies skip-changelog]
  config.future_release = "v#{Riemann::Tools::VERSION}"
end

desc 'Recursively build all gems'
task :rbuild do
  Dir.glob('tools/**') do |dir|
    Dir.chdir(dir)
    sh 'rake gem'
    Dir.chdir('../..')
  end
end

task build: :gen_parser

desc 'Generate parsers'
task gen_parser: [
  'lib/riemann/tools/mdstat_parser.tab.rb',
  'lib/riemann/tools/uptime_parser.tab.rb',
]

file 'lib/riemann/tools/mdstat_parser.tab.rb' => 'lib/riemann/tools/mdstat_parser.y' do
  sh 'racc -S lib/riemann/tools/mdstat_parser.y'
end

file 'lib/riemann/tools/uptime_parser.tab.rb' => 'lib/riemann/tools/uptime_parser.y' do
  sh 'racc -S lib/riemann/tools/uptime_parser.y'
end
