require_relative 'puppet_module'
require_relative 'control_repo'
require 'gitlab'
require 'rugged'
require 'fileutils'
require 'release_manager/logger'
require 'release_manager/vcs_manager'

class Sandbox
  attr_reader :modules, :name, :repos_dir, :options,
              :control_repo, :module_names, :control_repo_path, :vcs

  include ReleaseManager::Logger

  def initialize(name, modules, control_repo_path, repos_dir = nil, options = {})
    @name = name
    @repos_dir = repos_dir
    @module_names = modules
    @control_repo_path = control_repo_path
    @vcs = ReleaseManager::VCSManager.default_instance
    @options = options
  end

  # @param [String] repos_path - the path to the repos directory where you want to clone modules
  # @return [String] the repos_path
  # Creates the repos path using mkdir_p unless the path already exists
  def setup_repos_dir(repos_path)
    FileUtils.mkdir_p(repos_path) unless File.exists?(repos_path)
    repos_path
  end

  # @return [String] the repos_path, defaults to ~/repos
  def repos_dir
    @repos_dir ||= File.expand_path(File.join(ENV['HOME'], 'repos'))
  end

  # @return [String] the r10k control repo path, defaults to ~/repos/r10k-control
  def control_repo_path
    @control_repo_path ||= File.expand_path(File.join(repos_dir, 'r10k-control'))
  end

  # @return [ControlRepo] - a ControlRepo object
  def control_repo
    @control_repo ||= ControlRepo.new(control_repo_path)
  end

  # @return [ControlRepo] - creates a new control repo object and clones the url unless already cloned
  # @param [String] url - the url to clone and fork
  def setup_control_repo(url)
    # clone r10k unless already cloned
    puts "## r10k-control ##".yellow
    fork = create_repo_fork(url)
    c = ControlRepo.create(control_repo_path, fork.ssh_url_to_repo)
    c.add_remote(fork.ssh_url_to_repo, 'myfork')
    c.fetch('myfork')
    c.fetch('origin')
    c.add_remote(url, 'upstream')
    # if the user doesn't have the branch, we create from upstream
    # and then checkout from the fork, we defer pushing the branch to later after updating the puppetfile
    target = c.branch_exist?("upstream/#{name}") ? "upstream/#{name}" : 'upstream/dev'
    # if the user has previously created the branch but doesn't exist locally, no need to create
    c.create_branch(name, target)
    c.checkout_branch(name)
    c
  end

  # @return [PuppetModule] - creates a new puppet_module object and clones the url unless already cloned
  # @param [ControlMod] mod - the module to clone and fork
  # @param [Boolean] create_fork - defaults to true which creates a fork
  # if the fork is already created, do nothing
  def setup_module_repo(mod)
    raise InvalidModule.new(mod) unless mod.instance_of?(ControlMod)
    fork = create_repo_fork(mod.repo)
    m = PuppetModule.create(File.join(repos_dir, mod.name), fork.ssh_url_to_repo, name)
    m.fetch('origin')
    m.add_remote(fork.ssh_url_to_repo, 'myfork')
    # without the following, we risk accidently setting the upstream to the newly forked url
    # this occurs because r10k-control branch contains the forked url instead of the upstream url
    # we assume the metadata.source attribute contains the correct upstream url
    begin
      delay_source_change = false
      if m.source =~ /\Agit\@/
        m.add_remote(m.source, 'upstream', true)
      else
        logger.warn("Module's source is not defined correctly for #{m.name} should be a git url, fixing...")
        # delay the changing of metadata source until we checkout the branch
        delay_source_change = true
        m.add_remote(mod.repo, 'upstream', true)
      end
    rescue ModNotFoundException => e
      logger.error("Is #{mod.name} a puppet module?  Can't find the metadata source")
    end
    # if the user doesn't have the branch, we create from upstream
    # and then checkout from the fork
    # if the user has previously created the branch but doesn't exist locally, no need to create
    if m.remote_exists?('upstream')
      target = m.branch_exist?("myfork/#{name}") ? "myfork/#{name}" : 'upstream/master'
    else
      # don't create from upstream since the upstream remote does not exist
      # upstream does not exist because the url in the metadata source is not a git url
      target = 'master'
    end
    m.create_branch(name, target)
    m.push_branch('myfork', name)
    m.checkout_branch(name)
    if delay_source_change
      m.source = mod.repo
      m.commit_metadata_source
    end
    logger.info("Updating r10k-control Puppetfile to use fork: #{fork.ssh_url_to_repo} with branch: #{name}")
    puppetfile.write_source(mod.name, fork.ssh_url_to_repo, name )
    m
  end

  def setup_new_module(mod_name)
    repo_url = nil
    loop do
      print "Please enter the git url of the source repo : ".yellow
      repo_url = gets.chomp
      break if repo_url =~ /git\@/
      puts "Repo Url must be a git url".red
    end
    puppetfile.add_module(mod_name, git: repo_url)
  end

  # checkout and/or create branch
  # get modules
  # fork module unless already exists
  # clone fork of module
  # create branch of fork
  # set module fork
  # set module branch
  # set upstream to original namespace
  # cleanup branches
  def create(r10k_url)
    setup_repos_dir(repos_dir)
    @control_repo = setup_control_repo(r10k_url)
    # get modules we are interested in
    module_names.each do | mod_name |
      puts "## #{mod_name} ##".yellow
      begin
        mod = puppetfile.find_mod(mod_name)
        setup_module_repo(mod)
      rescue InvalidModuleNameException => e
        logger.error(e.message)
        value = nil
        loop do
          print "Do you want to create a new entry in the Puppetfile for the module named #{mod_name}?(y/n): ".yellow
          value = gets.downcase.chomp
          break if value =~ /y|n/
        end
        next if value == 'n'
        mod = setup_new_module(mod_name)
        setup_module_repo(mod)
      end
    end
    @control_repo.checkout_branch(name)
    puppetfile.write_to_file
    logger.info("Committing Puppetfile changes to r10k-control branch: #{name}")
    puppetfile.commit("Sandbox Creation for #{name} environment")
    logger.info("Pushing new environment branch: #{name} to upstream")
    puppetfile.push('upstream', name, true)
    return self
  end

  # @param [String] url - a git url
  # @return [String] a string representing the project id from gitlab
  # gets the project id from gitlab using the remote API
  def repo_id(url)
    # ie. git@server:namespace/project.git
    proj = url.match(/:(.*\/.*)\.git/)
    raise RepoNotFound unless proj
    # the gitlab api is supposed to encode the slash, but currently that doesn't seem to work
    proj[1].gsub('/', '%2F')
  end

  # TODO: extract this out to an adapter
  def verify_api_token
    begin
      Gitlab.user
    rescue Exception => e
      raise InvalidToken.new(e.message)
    end
  end

  # TODO: extract this out to an adapter
  # replaces namespace from the url with the supplied or default namespace
  def swap_namespace(url, namespace = nil)
    url.gsub(/\:([\w-]+)\//, ":#{namespace || Gitlab.user.username}/")
  end

  # @return [Gitlab::ObjectifiedHash] Information about the forked project
  # @param [ControlMod] the module you want to fork
  # TODO: extract this out to an adapter
  def create_repo_fork(url, namespace = nil )
    new_url = swap_namespace(url, namespace)
    repo = repo_exists?(new_url)
    unless repo
      upstream_repo_id = repo_id(url)
      logger.info("Forking project from #{url} to #{new_url}")
      repo = Gitlab.create_fork(upstream_repo_id)
      # gitlab lies about having completed the forking process, so lets sleep until it is actually done
      loop do
        sleep(1)
        break if repo_exists?(repo.ssh_url_to_repo)
      end
    end
    vcs.add_permissions(repo.id, options[:default_members])
    repo
  end

  # @param [String] url - the git url of the repository
  # @return [Boolean] returns the project object (true) if found, false otherwise
  # TODO: extract this out to an adapter
  def repo_exists?(url)
    upstream_repo_id = repo_id(url)
    begin
      Gitlab.project(upstream_repo_id)
    rescue
      false
    end
  end

  # @return String - the branch name that was created
  # TODO: extract this out to an adapter
  def create_repo_branch(repo_id, branch_name)
    Gitlab.repo_create_branch(repo_id, branch_name)
  end

  # TODO: extract this out to an adapter
  def clone_repo(mod_name, url)
    path = File.join(repos_dir, mod_name)
    Rugged::Repository.clone_at(url, path, checkout_branch: name)
  end

  # @returns [Hash[PuppetModules]] an hash of puppet modules
  def modules
    @modules ||= puppetfile.find_mods(module_names)
  end

  def puppetfile 
    @puppetfile ||= control_repo.puppetfile
  end

  def check_requirements
    begin
      vcs.add_ssh_key
    rescue InvalidModuleNameException => e
      logger.error(e.message)
      exit 1
    end
  end

  # @param [String] name - the name of the sandbox
  # @param [Array[String] modules - the names of the modules that should be forked and branched
  # @param [String] repos_dir - the path to the repos directory
  # @param [String] control_repo_path - the url or path to the r10k control repo
  # @option [String] fork_namespace - the namespace from which you fork modules to
  #
  # the user passes in the r10k git url or path or we assume the path
  # if the user does not pass in the git url we assume the repo already exist
  # if the repo doesn't exist we clone the url
  def self.create(name, options)
    box = Sandbox.new(name, options[:modules],
                      options[:r10k_repo_path],
                      options[:repos_path], options)
    box.check_requirements
    box.verify_api_token
    box.create(options[:r10k_repo_url])
  end

end
