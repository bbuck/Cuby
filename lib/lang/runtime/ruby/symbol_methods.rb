module EleetScript
  Memory.define_core_methods do
    symbol = root_namespace["Symbol"]

    symbol.class_def :new do |receiver, arguments, context|
      if arguments.length > 0
        receiver.new_with_value(arguments.first.call(:to_string).ruby_value.intern, context.namespace_context)
      else
        reciever.new_with_value(:nil, context.namespace_context)
      end
    end

    symbol.def :is do |receiver, arguments|
      t, f = root_namespace["true"], root_namespace["false"]
      if arguments.length == 0
        f
      else
        (receiver.ruby_value == arguments.first.ruby_value ? t : f)
      end
    end

    symbol.def :to_string do |receiver, arguments, context|
      root_namespace["String"].new_with_value("#{receiver.ruby_value.to_s}", context.namespace_context)
    end
  end
end