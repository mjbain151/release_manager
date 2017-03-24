# frozen_string_literal: true
require_relative 'pmodule'
require_relative 'errors'
require 'json'

class Puppetfile
  attr_accessor :modules, :puppetfile, :data, :base_path
  BUMP_TYPES = %w{patch minor major}

  # @param [String] puppetfile - the path to the puppetfile
  def initialize(puppetfile = 'Puppetfile')
    @puppetfile = puppetfile
  end

  def base_path
    @base_path ||= File.dirname(puppetfile)
  end

  def git_command
    "git --work-tree=#{base_path} --git-dir=#{base_path}/.git"
  end

  def commit(message)
    puts `#{git_command} add #{puppetfile}`
    puts `#{git_command} commit -n -m "[Autobot] - #{message}"`
  end

  def current_branch
    `#{git_command} rev-parse --abbrev-ref HEAD`
  end

  def push(remote, branch)
    `#{git_command} push #{remote} #{branch}`
  end

  def data
    unless @data
      @data = File.read(puppetfile)
    end
    @data
  end

  def modules
    unless @modules
      @modules = {}
      instance_eval(data) if data
    end
    @modules
  end

  def self.from_string(s)
    instance = new
    instance.data = s
    instance
  end

  def find_mod(name)
    mod = modules[name] || modules.find{ |module_name, mod| mod.metadata[:git] =~ /#{name}/i }
    raise InvalidModuleNameException "Invalid module module name #{name}, cannot locate in Puppetfile" unless mod
    mod
  end

  def write_version(mod_name, version)
    mod = find_mod(mod_name)
    mod.version = version
  end

  def bump(mod_name, type = 'patch')
    raise "Invalid type, must be one of #{BUMP_TYPES}" unless BUMP_TYPES.include?(type)
    mod = find_mod(mod_name)
    find_mod(mod_name).send("bump_#{type}_version")
  end

  def to_json(pretty = false)
    if pretty
      JSON.pretty_generate(modules)
    else
      modules.to_json
    end
  end

  def to_puppetfile
    File.write(puppetfile, to_s)
  end

  def to_s
    modules.collect {|n, mod| mod.to_s }.join("\n\n")
  end

  def self.to_puppetfile(json_data)
    obj = JSON.parse(json_data)
    mods = obj.collect do |name, metadata|
      name = "mod '#{name}',"
      data = metadata.sort.map { |k, v| ":#{k} => '#{v}'" }.join(",\n\  ")
      "#{name}\n  #{data}\n"
    end.join("\n")
    mods
  end

  def mod(name, *args)
    @modules[name] = PModule.new(name, args.flatten.first)
  end

end
