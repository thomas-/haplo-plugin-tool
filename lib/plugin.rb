# Haplo Plugin Tool             http://docs.haplo.org/dev/tool/plugin
# (c) Haplo Services Ltd 2006 - 2016    http://www.haplo-services.com
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.


module PluginTool

  class Plugin
    DEFAULT_PLUGIN_LOAD_PRIORITY = 9999999

    def initialize(name, options)
      @name = name
      @options = options
    end
    attr_accessor :name
    attr_accessor :plugin_dir
    attr_accessor :loaded_plugin_id

    # ---------------------------------------------------------------------------------------------------------

    @@pending_apply = []

    # ---------------------------------------------------------------------------------------------------------

    def start
      # Check to see if the plugin is valid
      unless File.file?("#{@name}/plugin.json")
        end_on_error "Plugin #{@name} does not exist (no plugin.json file)"
      end
      # Setup for using the plugin
      @plugin_dir = @name
      end_on_error "logic error" unless @plugin_dir =~ /\A[a-zA-Z0-9_-]+\z/
      @loaded_plugin_id = nil
    end

    def plugin_load_priority
      pj = File.open("#{@plugin_dir}/plugin.json") { |f| JSON.parse(f.read) }
      pj['loadPriority'] || DEFAULT_PLUGIN_LOAD_PRIORITY
    end

    def print_banner
      puts "Plugin: #{@plugin_dir}"
    end

    def setup_for_server
      # Make the first empty manifest (may be replaced from server)
      @current_manifest = {}

      # If minimisation is active, clear the current manifest so all files are uploaded again.
      if @options.minimiser != nil
        @current_manifest = {}
      end

      # See if the plugin has already been registered with the server
      s_found_info = PluginTool.post_with_json_response("/api/development-plugin-loader/find-registration", {:name => @name})
      if s_found_info["found"]
        # Store info returned by the server
        @loaded_plugin_id = s_found_info["plugin_id"]
        @current_manifest = s_found_info["manifest"]
      end

      # If there isn't an existing plugin registered, create a new one
      if @loaded_plugin_id == nil
        s_create_info = PluginTool.post_with_json_response("/api/development-plugin-loader/create")
        end_on_error "Couldn't communicate successfully with server." if s_create_info["protocol_error"]
        end_on_error "Failed to create plugin on server" unless s_create_info["plugin_id"] != nil
        @loaded_plugin_id = s_create_info["plugin_id"]
      end
    end

    # ---------------------------------------------------------------------------------------------------------

    def exclude_files_from_syntax_check
      @exclude_files_from_syntax_check ||= begin
        # developer.json file might contain some files which should not be syntax checked
        exclude_files_from_check = []
        developer_json_pathname = "#{@plugin_dir}/developer.json"
        if File.exist? developer_json_pathname
          developer_json = JSON.parse(File.read(developer_json_pathname))
          if developer_json['excludeFromSyntaxCheck'].kind_of?(Array)
            exclude_files_from_check = developer_json['excludeFromSyntaxCheck']
          end
        end
        exclude_files_from_check
      end
    end

    # ---------------------------------------------------------------------------------------------------------

    def command(cmd)
      case cmd
      when 'license-key'
        application_id = @options.args.first
        if application_id == nil || application_id !~ /\A\d+\z/
          end_on_error "Numeric application ID must be specified"
        end
        generate_license_key(application_id)

      when 'pack'
        PluginTool.pack_plugin(@name, @options.output)

      when 'reset-db'
        puts "Resetting database on server for #{@name}..."
        reset_result = PluginTool.post_with_json_response("/api/development-plugin-loader/resetdb/#{@loaded_plugin_id}")
        end_on_error "Couldn't remove old database tables" unless reset_result["result"] == 'success'
        apply_result = PluginTool.post_with_json_response("/api/development-plugin-loader/apply", :plugins => @loaded_plugin_id)
        end_on_error "Couldn't apply changes" unless apply_result["result"] == 'success'
        puts "Done."

      when 'uninstall'
        puts "Uninstalling plugin #{@name} from server..."
        reset_result = PluginTool.post_with_json_response("/api/development-plugin-loader/uninstall/#{@loaded_plugin_id}")
        end_on_error "Couldn't uninstall plugin" unless reset_result["result"] == 'success'
        puts "Done."

      when 'test'
        puts "Running tests..."
        params = {}
        params["test"] = @options.args.first unless @options.args.empty?
        test_result = PluginTool.post_with_json_response("/api/development-plugin-loader/run-tests/#{@loaded_plugin_id}", params)
        end_on_error "Couldn't run tests" unless test_result["result"] == 'success'
        puts
        puts test_result["output"] || ''
        puts test_result["summary"] || "(unknown results)"

      when 'develop'
        # do nothing here

      else
        end_on_error "Unknown command '#{cmd}'"

      end
    end

    # ---------------------------------------------------------------------------------------------------------

    def develop_setup
    end

    def develop_scan_and_upload(first_run)
      should_apply = first_run
      next_manifest = PluginTool.generate_manifest(@plugin_dir)
      if !(next_manifest.has_key?("plugin.json"))
        # If the plugin.json file is deleted, just uninstall the plugin from the server
        command('uninstall')
        @is_uninstalled = true
        return
      elsif @is_uninstalled
        should_apply = true
      end
      changes = PluginTool.determine_manifest_changes(@current_manifest, next_manifest)
      upload_failed = false
      changes.each do |filename, action|
        filename =~ /\A(.*?\/)?([^\/]+)\z/
        params = {:filename => $2}
        params[:directory] = $1.gsub(/\/\z/,'') if $1
        if action == :delete
          puts "  #{@name}: Deleting #{filename}"
          PluginTool.post_with_json_response("/api/development-plugin-loader/delete-file/#{@loaded_plugin_id}", params)
        else
          puts "  #{@name}: Uploading #{filename}"
          data = File.open("#{@plugin_dir}/#{filename}") { |f| f.read }
          hash = action
          # Minimise file before uploading?
          if @options.minimiser != nil && filename =~ /\A(static|template)\//
            size_before = data.length
            data = @options.minimiser.process(data, filename)
            size_after = data.length
            hash = Digest::SHA256.hexdigest(data)
            puts "        minimisation: #{size_before} -> #{size_after} (#{(size_after * 100) / size_before}%)"
          end
          r = PluginTool.post_with_json_response("/api/development-plugin-loader/put-file/#{@loaded_plugin_id}", params, {:file => [filename, data]})
          if r["result"] == 'success'
            # If the file was uploaded successfully, but the hash didn't match, abort now
            end_on_error "#{@name}: Disagreed with server about uploaded file hash: local=#{hash}, remote=#{r["hash"]}" unless hash == r["hash"]
          else
            # Otherwise mark as a failed upload to stop an apply operation which will fail
            upload_failed = true
          end
          PluginTool.syntax_check(self, filename) if filename =~ /\.(js|hsvt)\z/i
        end
      end
      if upload_failed
        puts "\n#{@name}: Not applying changes due to failure\n\n"
      else
        if !(changes.empty?) || should_apply
          @@pending_apply.push(self) unless @@pending_apply.include?(self)
        end
      end
      @current_manifest = next_manifest
    end

    # ---------------------------------------------------------------------------------------------------------

    def self.do_apply
      return if @@pending_apply.empty?
      puts "Applying changes on server: #{@@pending_apply.map { |p| p.name } .join(', ')}"
      r = PluginTool.post_with_json_response("/api/development-plugin-loader/apply", {
        :plugins => @@pending_apply.map { |p| p.loaded_plugin_id }.join(' ')
      })
      if r["result"] == 'success'
        @@pending_apply = []
      else
        puts "\n\nDidn't apply changes on server\n\n"
        PluginTool.beep
      end
    end

    # ---------------------------------------------------------------------------------------------------------

    def generate_license_key(application_id)
      info = File.open("#{@plugin_dir}/plugin.json") { |f| JSON.parse(f.read) }
      if info["installSecret"] == nil
        end_on_error "#{@name}: No installSecret specified in plugin.json"
      end
      license_key = HMAC::SHA1.sign(info["installSecret"], "application:#{application_id}")
      puts <<__E

Plugin:       #{@name}
Application:  #{application_id}
License key:  #{license_key}
__E
    end

    def end_on_error(err)
      puts err
      exit 1
    end
  end

end