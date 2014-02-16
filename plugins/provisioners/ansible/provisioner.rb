module VagrantPlugins
  module Ansible
    class Provisioner < Vagrant.plugin("2", :provisioner)
      def provision
        @logger = Log4r::Logger.new("vagrant::provisioners::ansible")
        ssh = @machine.ssh_info

        # Connect with Vagrant user (unless --user or --private-key are
        # overidden by 'raw_arguments').
        #
        # TODO: multiple private key support
        options = %W[--private-key=#{ssh[:private_key_path][0]} --user=#{ssh[:username]}]

        # Joker! Not (yet) supported arguments can be passed this way.
        options.concat(self.as_array(config.raw_arguments)) if config.raw_arguments

        # By default we limit by the current machine.  This can be
        # overriden by the limit config option.
        limit_option = if config.limit == nil
                         "--limit=#{@machine.name}"
                       elsif not config.limit.empty?
                         "--limit=#{as_list_argument(config.limit)}"
                       end

        # Append Provisioner options (highest precedence):
        options << "--inventory-file=#{self.setup_inventory_file}"
        options << "--extra-vars=#{self.get_extra_vars_argument}" if config.extra_vars
        options << "--sudo" if config.sudo
        options << "--sudo-user=#{config.sudo_user}" if config.sudo_user
        options << "#{self.get_verbosity_argument}" if config.verbose
        options << "--ask-sudo-pass" if config.ask_sudo_pass
        options << "--tags=#{as_list_argument(config.tags)}" if config.tags
        options << "--skip-tags=#{as_list_argument(config.skip_tags)}" if config.skip_tags
        options << limit_option if limit_option
        options << "--start-at-task=#{config.start_at_task}" if config.start_at_task

        # Assemble the full ansible-playbook command
        command = (%w(ansible-playbook) << options << config.playbook).flatten

        # Write stdout and stderr data, since it's the regular Ansible output
        command << {
          :env => {
            "ANSIBLE_FORCE_COLOR" => "true",
            "ANSIBLE_HOST_KEY_CHECKING" => "#{config.host_key_checking}",
            # Ensure Ansible output isn't buffered so that we receive ouput
            # on a task-by-task basis.
            "PYTHONUNBUFFERED" => 1
          },
          :notify => [:stdout, :stderr],
          :workdir => @machine.env.root_path.to_s
        }

        begin
          result = Vagrant::Util::Subprocess.execute(*command) do |type, data|
            if type == :stdout || type == :stderr
              @machine.env.ui.info(data, :new_line => false, :prefix => false)
            end
          end

          raise Vagrant::Errors::AnsibleFailed if result.exit_code != 0
        rescue Vagrant::Util::Subprocess::LaunchError
          raise Vagrant::Errors::AnsiblePlaybookAppNotFound
        end
      end

      protected

      # Auto-generate "safe" inventory file based on Vagrantfile,
      # unless inventory_path is explicitly provided
      def setup_inventory_file
        return config.inventory_path if config.inventory_path

        ssh = @machine.ssh_info

        # Managed machines
        inventory_machines = {}

        generated_inventory_file =
          @machine.env.root_path.join("vagrant_ansible_inventory")

        generated_inventory_file.open('w') do |file|
          file.write("# Generated by Vagrant\n\n")

          @machine.env.active_machines.each do |am|
            begin
              m = @machine.env.machine(*am)
              if !m.ssh_info.nil?
                file.write("#{m.name} ansible_ssh_host=#{m.ssh_info[:host]} ansible_ssh_port=#{m.ssh_info[:port]}\n")
                inventory_machines[m.name] = m
              else
                @logger.error("Auto-generated inventory: Impossible to get SSH information for machine '#{m.name} (#{m.provider_name})'. This machine should be recreated.")
                # Let a note about this missing machine
                file.write("# MISSING: '#{m.name}' machine was probably removed without using Vagrant. This machine should be recreated.\n")
              end
            rescue Vagrant::Errors::MachineNotFound => e
              @logger.info("Auto-generated inventory: Skip machine '#{am[0]} (#{am[1]})', which is not configured for this Vagrant environment.")
            end
          end

          # Write out groups information.
          # All defined groups will be included, but only supported
          # machines and defined child groups will be included.
          # Group variables are intentionally skipped.
          groups_of_groups = {}
          defined_groups = []

          config.groups.each_pair do |gname, gmembers|
            # Require that gmembers be an array
            # (easier to be tolerant and avoid error management of few value)
            gmembers = [gmembers] if !gmembers.is_a?(Array)

            if gname.end_with?(":children")
              groups_of_groups[gname] = gmembers
              defined_groups << gname.sub(/:children$/, '')
            elsif !gname.include?(':vars')
              defined_groups << gname
              file.write("\n[#{gname}]\n")
              gmembers.each do |gm|
                file.write("#{gm}\n") if inventory_machines.include?(gm.to_sym)
              end
            end
          end

          defined_groups.uniq!
          groups_of_groups.each_pair do |gname, gmembers|
            file.write("\n[#{gname}]\n")
            gmembers.each do |gm|
              file.write("#{gm}\n") if defined_groups.include?(gm)
            end
          end
        end

        return generated_inventory_file.to_s
      end

      def get_extra_vars_argument
        if config.extra_vars.kind_of?(String) and config.extra_vars =~ /^@.+$/
          # A JSON or YAML file is referenced (requires Ansible 1.3+)
          return config.extra_vars
        else
          # Expected to be a Hash after config validation. (extra_vars as
          # JSON requires Ansible 1.2+, while YAML requires Ansible 1.3+)
          return config.extra_vars.to_json
        end
      end

      def get_verbosity_argument
        if config.verbose.to_s =~ /^v+$/
          # ansible-playbook accepts "silly" arguments like '-vvvvv' as '-vvvv' for now
          return "-#{config.verbose}"
        else
          # safe default, in case input strays
          return '-v'
        end
      end

      def as_list_argument(v)
        v.kind_of?(Array) ? v.join(',') : v
      end

      def as_array(v)
        v.kind_of?(Array) ? v : [v]
      end
    end
  end
end
