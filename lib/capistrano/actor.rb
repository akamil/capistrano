require 'erb'
require 'capistrano/command'
require 'capistrano/transfer'
require 'capistrano/gateway'
require 'capistrano/ssh'
require 'capistrano/utils'

module Capistrano

  # An Actor is the entity that actually does the work of determining which
  # servers should be the target of a particular task, and of executing the
  # task on each of them in parallel. An Actor is never instantiated
  # directly--rather, you create a new Configuration instance, and access the
  # new actor via Configuration#actor.
  class Actor

    # An adaptor for making the SSH interface look and act like that of the
    # Gateway class.
    class DefaultConnectionFactory #:nodoc:
      def initialize(config)
        @config= config
      end

      def connect_to(server)
        SSH.connect(server, @config)
      end
    end

    class <<self
      attr_accessor :connection_factory
      attr_accessor :command_factory
      attr_accessor :transfer_factory
      attr_accessor :default_io_proc
    end

    self.connection_factory = DefaultConnectionFactory
    self.command_factory = Command
    self.transfer_factory = Transfer

    self.default_io_proc = Proc.new do |ch, stream, out|
      level = out == :error ? :important : :info
      ch[:actor].logger.send(level, out, "#{stream} :: #{ch[:host]}")
    end

    # The configuration instance associated with this actor.
    attr_reader :configuration

    # A hash of the tasks known to this actor, keyed by name. The values are
    # instances of Actor::Task.
    attr_reader :tasks

    # A hash of the SSH sessions that are currently open and available.
    # Because sessions are constructed lazily, this will only contain
    # connections to those servers that have been the targets of one or more
    # executed tasks.
    attr_reader :sessions

    # The call stack of the tasks. The currently executing task may inspect
    # this to see who its caller was. The current task is always the last
    # element of this stack.
    attr_reader :task_call_frames

    # The history of executed tasks. This will be an array of all tasks that
    # have been executed, in the order in which they were called.
    attr_reader :task_call_history

    # A struct for representing a single instance of an invoked task.
    TaskCallFrame = Struct.new(:name, :rollback)

    # Represents the definition of a single task.
    class Task #:nodoc:
      attr_reader :name, :actor, :options

      def initialize(name, actor, options)
        @name, @actor, @options = name, actor, options
        @servers = nil
      end

      # Returns the list of servers (_not_ connections to servers) that are
      # the target of this task.
      def servers
        unless @servers
          roles = [*(@options[:roles] || actor.configuration.roles.keys)].
            map { |name|
              actor.configuration.roles[name] or
                raise ArgumentError, "task #{self.name.inspect} references non-existant role #{name.inspect}"
            }.flatten
          only  = @options[:only] || {}

          unless only.empty?
            roles = roles.delete_if do |role|
              catch(:done) do
                only.keys.each do |key|
                  throw(:done, true) if role.options[key] != only[key]
                end
                false
              end
            end
          end

          @servers = roles.map { |role| role.host }.uniq
        end

        @servers
      end
    end

    def initialize(config) #:nodoc:
      @configuration = config
      @tasks = {}
      @task_call_frames = []
      @sessions = {}
      @factory = self.class.connection_factory.new(configuration)
    end

    # Define a new task for this actor. The block will be invoked when this
    # task is called.
    def define_task(name, options={}, &block)
      @tasks[name] = (options[:task_class] || Task).new(name, self, options)
      define_method(name) do
        send "before_#{name}" if respond_to? "before_#{name}"
        logger.debug "executing task #{name}"
        begin
          push_task_call_frame name
          result = instance_eval(&block)
        ensure
          pop_task_call_frame
        end
        send "after_#{name}" if respond_to? "after_#{name}"
        result
      end
    end

    # Iterates over each task, in alphabetical order. A hash object is
    # yielded for each task, which includes the task's name (:name), the
    # length of the longest task name (:longest), and the task's description,
    # reformatted as a single line (:desc).
    def each_task
      keys = tasks.keys.sort_by { |a| a.to_s }
      longest = keys.inject(0) { |len,key| key.to_s.length > len ? key.to_s.length : len } + 2

      keys.sort_by { |a| a.to_s }.each do |key|
        desc = (tasks[key].options[:desc] || "").gsub(/(?:\r?\n)+[ \t]*/, " ").strip
        info = { :task => key, :longest => longest, :desc => desc }
        yield info
      end
    end

    # Dump all tasks and (brief) descriptions in YAML format for consumption
    # by other processes. Returns a string containing the YAML-formatted data.
    def dump_tasks
      data = ""
      each_task do |info|
        desc = info[:desc].split(/\. /).first || ""
        desc << "." if !desc.empty? && desc[-1] != ?.
        data << "#{info[:task]}: #{desc}\n"
      end
      data
    end

    # Execute the given command on all servers that are the target of the
    # current task. If a block is given, it is invoked for all output
    # generated by the command, and should accept three parameters: the SSH
    # channel (which may be used to send data back to the remote process),
    # the stream identifier (<tt>:err</tt> for stderr, and <tt>:out</tt> for
    # stdout), and the data that was received.
    #
    # If +pretend+ mode is active, this does nothing.
    def run(cmd, options={}, &block)
      block ||= default_io_proc
      logger.debug "executing #{cmd.strip.inspect}"

      execute_on_servers(options) do |servers|
        # execute the command on each server in parallel
        command = self.class.command_factory.new(servers, cmd, block, options, self)
        command.process! # raises an exception if command fails on any server
      end
    end

    # Deletes the given file from all servers targetted by the current task.
    # If <tt>:recursive => true</tt> is specified, it may be used to remove
    # directories.
    def delete(path, options={})
      cmd = "rm -%sf #{path}" % (options[:recursive] ? "r" : "")
      run(cmd, options)
    end

    # Store the given data at the given location on all servers targetted by
    # the current task. If <tt>:mode</tt> is specified it is used to set the
    # mode on the file.
    def put(data, path, options={})
      if Capistrano::SFTP
        execute_on_servers(options) do |servers|
          transfer = self.class.transfer_factory.new(servers, self, path, :data => data,
            :mode => options[:mode])
          transfer.process!
        end
      else
        # Poor-man's SFTP... just run a cat on the remote end, and send data
        # to it.

        cmd = "cat > #{path}"
        cmd << " && chmod #{options[:mode].to_s(8)} #{path}" if options[:mode]
        run(cmd, options.merge(:data => data + "\n\4")) do |ch, stream, out|
          logger.important out, "#{stream} :: #{ch[:host]}" if stream == :err
        end
      end
    end

    # Like #run, but executes the command via <tt>sudo</tt>. This assumes that
    # the sudo password (if required) is the same as the password for logging
    # in to the server.
    def sudo(command, options={}, &block)
      block ||= default_io_proc

      # in order to prevent _each host_ from prompting when the password was
      # wrong, let's track which host prompted first and only allow subsequent
      # prompts from that host.
      prompt_host = nil
      
      run "sudo #{command}", options do |ch, stream, out|
        if out =~ /^Password:/
          ch.send_data "#{password}\n"
        elsif out =~ /try again/
          if prompt_host.nil? || prompt_host == ch[:host]
            prompt_host = ch[:host]
            logger.important out, "#{stream} :: #{ch[:host]}"
            # reset the password to it's original value and prepare for another
            # pass (the reset allows the password prompt to be attempted again
            # if the password variable was originally a proc (the default)
            set :password, self[:original_value][:password] || self[:password]
          end
        else
          block.call(ch, stream, out)
        end
      end
    end

    # Renders an ERb template and returns the result. This is useful for
    # dynamically building documents to store on the remote servers.
    #
    # Usage:
    #
    #   render("something", :foo => "hello")
    #     look for "something.rhtml" in the current directory, or in the
    #     capistrano/recipes/templates directory, and render it with
    #     foo defined as a local variable with the value "hello".
    #
    #   render(:file => "something", :foo => "hello")
    #     same as above
    #
    #   render(:template => "<%= foo %> world", :foo => "hello")
    #     treat the given string as an ERb template and render it with
    #     the given hash of local variables active.
    def render(*args)
      options = args.last.is_a?(Hash) ? args.pop : {}
      options[:file] = args.shift if args.first.is_a?(String)
      raise ArgumentError, "too many parameters" unless args.empty?

      case
        when options[:file]
          file = options.delete :file
          unless file[0] == ?/
            dirs = [".",
              File.join(File.dirname(__FILE__), "recipes", "templates")]
            dirs.each do |dir|
              if File.file?(File.join(dir, file))
                file = File.join(dir, file)
                break
              elsif File.file?(File.join(dir, file + ".rhtml"))
                file = File.join(dir, file + ".rhtml")
                break
              end
            end
          end

          render options.merge(:template => File.read(file))

        when options[:template]
          erb = ERB.new(options[:template])
          b = Proc.new { binding }.call
          options.each do |key, value|
            next if key == :template
            eval "#{key} = options[:#{key}]", b
          end
          erb.result(b)

        else
          raise ArgumentError, "no file or template given for rendering"
      end
    end

    # Inspects the remote servers to determine the list of all released versions
    # of the software. Releases are sorted with the most recent release last.
    def releases
      unless @releases
        buffer = ""
        run "ls -x1 #{releases_path}", :once => true do |ch, str, out|
          buffer << out if str == :out
          raise "could not determine releases #{out.inspect}" if str == :err
        end
        @releases = buffer.split.sort
      end

      @releases
    end

    # Returns the most recent deployed release
    def current_release
      release_path(releases.last)
    end

    # Returns the release immediately before the currently deployed one
    def previous_release
      release_path(releases[-2])
    end

    # Invoke a set of tasks in a transaction. If any task fails (raises an
    # exception), all tasks executed within the transaction are inspected to
    # see if they have an associated on_rollback hook, and if so, that hook
    # is called.
    def transaction
      if task_call_history
        yield
      else
        logger.info "transaction: start"
        begin
          @task_call_history = []
          yield
          logger.info "transaction: commit"
        rescue Object => e
          current = task_call_history.last
          logger.important "transaction: rollback", current ? current.name : "transaction start"
          task_call_history.reverse.each do |task|
            begin
              logger.debug "rolling back", task.name
              task.rollback.call if task.rollback
            rescue Object => e
              logger.info "exception while rolling back: #{e.class}, #{e.message}", task.name
            end
          end
          raise
        ensure
          @task_call_history = nil
        end
      end
    end

    # Specifies an on_rollback hook for the currently executing task. If this
    # or any subsequent task then fails, and a transaction is active, this
    # hook will be executed.
    def on_rollback(&block)
      task_call_frames.last.rollback = block
    end

    # An instance-level reader for the class' #default_io_proc attribute.
    def default_io_proc
      self.class.default_io_proc
    end

    # Used to force connections to be made to the current task's servers.
    # Connections are normally made lazily in Capistrano--you can use this
    # to force them open before performing some operation that might be
    # time-sensitive.
    def connect!(options={})
      execute_on_servers(options) { }
    end

    def current_task
      return nil if task_call_frames.empty?
      tasks[task_call_frames.last.name]
    end

    def metaclass
      class << self; self; end
    end

    private

      def define_method(name, &block)
        metaclass.send(:define_method, name, &block)
      end

      def push_task_call_frame(name)
        frame = TaskCallFrame.new(name)
        task_call_frames.push frame
        task_call_history.push frame if task_call_history
      end

      def pop_task_call_frame
        task_call_frames.pop
      end

      def establish_connections(servers)
        @factory = establish_gateway if needs_gateway?
        servers.each do |server|
          @sessions[server] ||= @factory.connect_to(server)
        end
      end

      def establish_gateway
        logger.debug "establishing connection to gateway #{gateway}"
        @established_gateway = true
        Gateway.new(gateway, configuration)
      end

      def needs_gateway?
        gateway && !@established_gateway
      end

      def execute_on_servers(options)
        task = current_task
        servers = task.servers

        if servers.empty?
          raise "The #{task.name} task is only run for servers matching #{task.options.inspect}, but no servers matched"
        end

        servers = [servers.first] if options[:once]
        logger.trace "servers: #{servers.inspect}"

        if !pretend
          # establish connections to those servers, as necessary
          establish_connections(servers)
          yield servers
        end
      end

      def method_missing(sym, *args, &block)
        if @configuration.respond_to?(sym)
          @configuration.send(sym, *args, &block)
        else
          super
        end
      end

  end
end
