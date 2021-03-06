require 'set'
require 'surrounded/context/role_map'

# Some features are only available in versions of Ruby
# where this method is true
def module_method_rebinding?
  return @__module_method_rebinding__ if defined?(@__module_method_rebinding__)
  sample_method = Enumerable.instance_method(:to_a)
  @__module_method_rebinding__ = begin
    !!sample_method.bind(Object.new)
  rescue TypeError
    false
  end
end

module Surrounded
  module Context
    def self.extended(base)
      base.send(:include, InstanceMethods)
      base.singleton_class.send(:alias_method, :setup, :initialize)
    end

    def self.default_role_type
      @default_role_type ||= :module
    end

    def self.default_role_type=(type)
      @default_role_type = type
    end

    def new(*args, &block)
      instance = allocate
      instance.send(:preinitialize)
      instance.send(:initialize, *args, &block)
      instance.send(:postinitialize)
      instance
    end

    def triggers
      @triggers.dup
    end

    private

    def private_const_set(name, const)
      const = const_set(name, const)
      private_constant name
      const
    end

    def default_role_type
      @default_role_type ||= Surrounded::Context.default_role_type
    end

    def default_role_type=(type)
      @default_role_type = type
    end

    def role(name, type=nil, &block)
      role_type = type || default_role_type
      case role_type
      when :wrap, :wrapper then wrap(name, &block)
      when :interface then interface(name, &block)
      when :module then
        mod_name = name.to_s.gsub(/(?:^|_)([a-z])/){ $1.upcase }
        private_const_set(mod_name, Module.new(&block))
      else
        raise InvalidRoleType.new
      end
    end

    def wrap(name, &block)
      require 'delegate'
      wrapper_name = name.to_s.gsub(/(?:^|_)([a-z])/){ $1.upcase }
      klass = private_const_set(wrapper_name, Class.new(SimpleDelegator, &block))
      klass.send(:include, Surrounded)
    end

    if module_method_rebinding?
      def interface(name, &block)
        class_basename = name.to_s.gsub(/(?:^|_)([a-z])/){ $1.upcase }
        interface_name = class_basename + 'Interface'

        behavior = private_const_set(interface_name, Module.new(&block))

        require 'surrounded/context/negotiator'
        define_method(name) do
          instance_variable_set("@#{name}", Negotiator.new(role_map.assigned_player(name), behavior))
        end
      end
    end

    def apply_roles_on(which)
      @__apply_role_policy = which
    end

    def __apply_role_policy
      @__apply_role_policy ||= :trigger
    end

    def initialize(*setup_args)
      private_attr_reader(*setup_args)

      class_eval "
        def initialize(#{setup_args.join(',')})
          preinitialize
          arguments = method(__method__).parameters.map{|arg| eval(arg[1].to_s) }
          map_roles(#{setup_args}.zip(arguments))
          postinitialize
        end
      "
    end

    def private_attr_reader(*method_names)
      attr_reader(*method_names)
      private(*method_names)
    end

    def trigger(name, *args, &block)
      store_trigger(name)

      define_method(:"trigger_#{name}", *args, &block)

      private :"trigger_#{name}"

      define_method(name, *args){
        begin
          apply_roles if __apply_role_policy == :trigger

          self.send("trigger_#{name}", *args)

        ensure
          remove_roles if __apply_role_policy == :trigger
        end
      }
    end

    def store_trigger(name)
      @triggers ||= Set.new
      @triggers << name
    end

    def role_const(name)
      if const_defined?(name)
        const_get(name)
      end
    end

    module InstanceMethods
      def role?(name, &block)
        return false unless role_map.role?(name)
        accessor = eval('self', block.binding)
        role_map.role_player?(accessor) && role_map.assigned_player(name)
      end

      def triggers
        self.class.triggers
      end

      private

      def preinitialize
        @__apply_role_policy = self.class.send(:__apply_role_policy)
      end

      def postinitialize
        apply_roles if __apply_role_policy == :initialize
      end

      def role_map
        @role_map ||= RoleMap.new
      end

      def map_roles(role_object_array)
        role_object_array.each do |role, object|
          map_role(role, role_behavior_name(role), object)
        end
      end

      def map_role(role, mod_name, object)
        instance_variable_set("@#{role}", object)
        role_map.update(role, mod_name, object)
      end

      def __apply_role_policy
        @__apply_role_policy
      end

      def add_interface(role, behavior, object)
        applicator = behavior.is_a?(Class) ? method(:add_class_interface) : method(:add_module_interface)

        role_player = applicator.call(object, behavior)
        map_role(role, role_module_basename(behavior), role_player) if behavior
        role_player.store_context(self)
        role_player
      end

      def add_module_interface(obj, mod)
        adder_name = module_extension_methods.find{|meth| obj.respond_to?(meth) }
        return obj if !adder_name

        obj.method(adder_name).call(mod)
        obj
      end

      def add_class_interface(obj, klass)
        wrapper_name = wrap_methods.find{|meth| klass.respond_to?(meth) }
        return obj if !wrapper_name

        klass.method(wrapper_name).call(obj)
      end

      def remove_interface(role, behavior, object)
        remover_name = (module_removal_methods + unwrap_methods).find{|meth| object.respond_to?(meth) }
        return object if !remover_name

        object.remove_context
        role_player = object.method(remover_name).call

        map_role(role, role_module_basename(behavior), role_player) if behavior

        role_player
      end

      def apply_roles
        traverse_map method(:add_interface)
      end

      def remove_roles
        traverse_map method(:remove_interface)
      end

      def traverse_map(applicator)
        role_map.each do |role, mod_name, object|
          if role_const_defined?(mod_name)
            applicator.call(role, role_const(mod_name), object)
          end
        end
      end

      def module_extension_methods
        [:cast_as, :extend]
      end

      def wrap_methods
        [:new]
      end

      def module_removal_methods
        [:uncast]
      end

      def unwrap_methods
        [:__getobj__]
      end

      def role_behavior_name(role)
        role.to_s.gsub(/(?:^|_)([a-z])/) { $1.upcase }.sub(/_\d+/,'')
      end

      def role_module_basename(mod)
        mod.to_s.split('::').last
      end

      def role_const(name)
        self.class.send(:role_const, name)
      end

      def role_const_defined?(name)
        self.class.const_defined?(name)
      end
    end
  end
end