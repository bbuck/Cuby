require "lang/parser"
require "lang/runtime/memory"

module EleetScript
  class Interpreter
    attr_reader :memory
    def initialize(memory = nil)
      @parser = Parser.new
      @memory = memory || Memory.new
      @memory.bootstrap(self)
    end

    def eval(code, show_nodes = false)
      nodes = @parser.parse(code)
      puts nodes if show_nodes
      nodes.eval(@memory.root_namespace)
    end

    def load(file_name)
      if File.exists?(file_name)
        eval(File.read(file_name))
      end
    end
  end

  module InterpHelpers
    def self.global_name(name)
      name[1..-1]
    end

    def self.class_var_name(name)
      name[2..-1]
    end

    def self.instance_var_name(name)
      name[1..-1]
    end
  end
  H = InterpHelpers

  module Returnable
    def returned
      @returned = true
    end

    def returned?
      @returned
    end

    def reset_returned
      @returned = false
    end
  end

  module Nextable
    def nexted
      @nexted = true
    end

    def nexted?
      @nexted
    end

    def reset_nexted
      @nexted = false
    end
  end

  module NodeMethods
    def returnable?
      self.class.included_modules.include?(Returnable)
    end

    def nextable?
      self.class.included_modules.include?(Nextable)
    end
  end

  class Nodes
    include Returnable
    include Nextable

    def eval(context)
      return_value = nil
      nodes.each do |node|
        if node.kind_of?(ReturnNode)
          returned
          break return_value = node.eval(context)
        elsif node.kind_of?(NextNode)
          nexted
          break
        else
          return_value = node.eval(context)
        end
        if node.returnable? && node.returned?
          returned
          node.reset_returned
          break
        elsif node.nextable? && node.nexted?
          node.reset_nexted
          nexted
          break
        end
      end
      return_value || context.es_nil
    end
  end

  class StringNode
    INTERPOLATE_RX = /[\\]?%(?:@|@@|\$)?[\w]+?(?=\W|$)/

    def eval(context)
      context["String"].new_with_value(interpolate(context))
    end

    def interpolate(context)
      new_val = value.dup
      matches = value.scan(INTERPOLATE_RX)
      matches.each do |match|
        next if match.nil? || match == "%" || match == ""
        if match.start_with?("\\")
          next new_val.sub!(match, match[1..-1])
        end
        var = match[1..-1]
        new_val.sub!(match, context[var].call(:to_string).ruby_value)
      end
      new_val
    end
  end

  class IntegerNode
    def eval(context)
      context["Integer"].new_with_value(value)
    end
  end

  class FloatNode
    def eval(context)
      context["Float"].new_with_value(value)
    end
  end

  class SetGlobalNode
    def eval(context)
      context[name] = value.eval(context)
    end
  end

  class GetGlobalNode
    def eval(context)
      context[name]
    end
  end

  class GetLocalNode
    def eval(context)
      val = context[name]
      val != context.es_nil ? val : context.current_self.call(name, [])
    end
  end

  class SetLocalNode
    def eval(context)
      context[name] = value.eval(context)
    end
  end

  class GetConstantNode
    def eval(context)
      context.constants[name] || context[name]
    end
  end

  class SetConstantNode
    def eval(context)
      cur_val = context[name]
      if cur_val == context.es_nil
        context[name] = value.eval(context)
      end
    end
  end

  class SetInstanceVarNode
    def eval(context)
      context.instance_vars[H::instance_var_name(name)] = value.eval(context)
    end
  end

  class GetInstanceVarNode
    def eval(context)
      context.current_self.instance_vars[H::instance_var_name(name)]
    end
  end

  class TrueNode
    def eval(context)
      context["true"]
    end
  end

  class FalseNode
    def eval(context)
      context["false"]
    end
  end

  class NilNode
    def eval(context)
      context.es_nil
    end
  end

  class ClassNode
    def eval(context)
      cls = context[name]
      if cls == context.es_nil
        cls = if parent
          parent_cls = context[parent]
          throw "Cannot extend undefined class \"#{parent}\"." if parent_cls == context.es_nil
          EleetScriptClass.create(context, name, parent_cls)
        else
          EleetScriptClass.create(context, name)
        end
        context[name] = cls
      end

      body.eval(cls.context)
      cls
    end
  end

  class PropertyNode
    def eval(context)
      cls = context.current_class
      properties.each do |prop_name|
        cls.def "#{prop_name}=" do |receiver, arguments|
          receiver.instance_vars[prop_name] = arguments.first
        end

        cls.def prop_name do |receiver, arguments|
          receiver.instance_vars[prop_name]
        end
      end
    end
  end

  class CallNode
    def eval(context)
      value = if receiver
        receiver.eval(context)
      else
        context.current_self
      end
      evaled_args = arguments.map { |a| a.eval(context) }
      value.call(method_name, evaled_args)
    end
  end

  class DefMethodNode
    def eval(context)
      method_obj = EleetScriptMethod.new(method.params, method.body)
      context.current_class.methods[method_name] = method_obj
      context.nil_obj
    end
  end

  class SelfNode
    def eval(context)
      context.current_self
    end
  end

  class IfNode
    include Returnable
    include Nextable

    def eval(context)
      cond = condition.eval(context)
      cond = (cond.class? ? cond : cond.ruby_value)
      if cond
        ret = body.eval(context)
        if body.returnable? && body.returned?
          body.reset_returned
          returned
        elsif body.nextable? && body.nexted?
          body.reset_nexted
          nexted
          return context.es_nil
        end
        ret
      else
        unless else_node.nil?
          ret = else_node.eval(context)
          if else_node.returned?
            else_node.reset_returned
            returned
          elsif else_node.nexted?
            else_node.reset_nexted
            nexted
            return context.es_nil
          end
          ret
        end
      end
    end
  end

  class ElseNode
    include Returnable
    include Nextable

    def eval(context)
      ret = body.eval(context)
      if body.returnable? and body.returned?
        body.reset_returned
        returned
      elsif body.nextable? && body.nexted?
        body.reset_nexted
        nexted
        return context.es_nil
      end
      ret
    end
  end

  class ReturnNode
    def eval(context)
      if expression
        expression.eval(context)
      else
        context.es_nil
      end
    end
  end

  class WhileNode
    include Returnable

    def eval(context)
      val = condition.eval(context)
      ret = nil
      while val.ruby_value
        ret = body.eval(context)
        if body.returnable? && body.returned?
          body.reset_returned
          returned
          return ret
        elsif body.nextable? && body.nexted?
          body.reset_nexted
          next
        end
        val = condition.eval(context)
      end
      ret || context.es_nil
    end
  end
end