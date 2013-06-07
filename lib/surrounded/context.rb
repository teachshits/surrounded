require 'set'
module Surrounded
  module Context
    def self.extended(base)
      base.send(:include, InstanceMethods)
    end

    def setup(*setup_args)
      attr_reader(*setup_args)
      private(*setup_args)

      define_method(:initialize){ |*args|
        Hash[setup_args.zip(args)].each{ |role, object|

          role_module_name = Context.classify_string(role)
          klass = self.class

          if mod = klass.const_defined?(role_module_name) && !mod.is_a?(Class)
            object = Context.modify(object, klass.const_get(role_module_name))
          end

          roles[role.to_s] = object
          instance_variable_set("@#{role}", object)
        }
      }
    end

    def trigger(name, *args, &block)
      store_trigger(name)

      define_method(:"trigger_#{name}", *args, &block)

      private :"trigger_#{name}"

      define_method(name, *args){
        begin
          (Thread.current[:context] ||= []).unshift(self)
          self.send("trigger_#{name}", *args)
        ensure
          (Thread.current[:context] ||= []).shift
        end
      }
    end

    def triggers
      @triggers.dup
    end

    module InstanceMethods
      def role?(name, accessor)
        roles.values.include?(accessor) && roles[name.to_s]
      end

      private

      def roles
        @roles ||= {}
      end
    end

    private

    def store_trigger(name)
      @triggers ||= Set.new
      @triggers << name
    end

    def self.classify_string(string)
      string.to_s.gsub(/(?:^|_)([a-z])/) { $1.upcase }
    end

    def self.modify(obj, mod)
      return obj if mod.is_a?(Class)
      if obj.respond_to?(:cast_as)
        obj.cast_as(mod)
      else
        obj.extend(mod)
      end
    end
  end
end