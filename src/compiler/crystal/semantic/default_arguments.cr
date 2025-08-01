require "../syntax/ast"

class Crystal::Def
  def expand_default_arguments(program, args_size, named_args = nil)
    # If the named arguments cover all arguments with a default value and
    # they come in the same order, we can safely return this def without
    # needing a useless indirection.
    if !splat_index && !double_splat && named_args && args_size + named_args.size == args.size
      all_match = true
      named_args.each_with_index do |named_arg, i|
        arg = args[args_size + i]
        unless arg.external_name == named_arg
          all_match = false
          break
        end
      end
      if all_match
        return self
      end
    end

    # If there are no named args and all unspecified default arguments are magic
    # constants we can return ourself (magic constants will be filled later)
    if !named_args && !splat_index && !double_splat
      all_magic = true
      args_size.upto(args.size - 1) do |index|
        unless args[index].default_value.is_a?(MagicConstant)
          all_magic = false
          break
        end
      end
      if all_magic
        return self
      end
    end

    retain_body = block_arity || splat_index || double_splat || assigns_special_var? || macro_def? || args.any? { |arg| arg.default_value && arg.restriction }

    splat_index = self.splat_index
    double_splat = self.double_splat

    new_args = [] of Arg

    # Args before splat index
    if splat_index
      before_splat_size = Math.min(args_size, splat_index)
    else
      before_splat_size = args_size
    end

    before_splat_size.times do |index|
      new_args << args[index].clone
    end

    # Splat arg
    splat_size = 0

    if splat_index
      arg = args[splat_index]

      unless arg.external_name.empty?
        splat_names = [] of String

        splat_size = args_size - splat_index
        splat_size = 0 if splat_size < 0

        splat_size.times do |index|
          splat_name = program.new_temp_var_name
          splat_names << splat_name

          splat_arg = Arg.new(splat_name)
          splat_arg.annotations = arg.annotations.dup
          splat_arg.original_name = arg.original_name

          new_args << splat_arg
        end
      end
    end

    if named_args
      # When **opts is expanded for named arguments, we must use internal
      # names that won't clash with local variables defined in the method.
      named_args_temp_names = Array(String).new(named_args.size)

      new_name = String.build do |str|
        str << name
        named_args.each do |named_arg|
          str << ':'
          str << named_arg

          temp_name = program.new_temp_var_name
          named_args_temp_names << temp_name

          # If a named argument matches an argument's external name, use the internal name
          matching_arg = args.find { |arg| arg.external_name == named_arg }
          if matching_arg
            new_arg = Arg.new(matching_arg.name, external_name: named_arg)
            new_arg.annotations = matching_arg.annotations.dup
            new_arg.original_name = matching_arg.original_name
            new_args << new_arg
          else
            new_arg = Arg.new(temp_name, external_name: named_arg)
            if double_splat = self.double_splat
              new_arg.annotations = double_splat.annotations.dup
              new_arg.original_name = double_splat.original_name
            end
            new_args << new_arg
          end
        end
      end
    else
      new_name = name
    end

    expansion = Def.new(new_name, new_args, nil, receiver.clone, block_arg.clone, return_type.clone, macro_def?, block_arity).at(self)
    expansion.args.each { |arg| arg.default_value = nil }
    expansion.calls_super = calls_super?
    expansion.calls_initialize = calls_initialize?
    expansion.calls_previous_def = calls_previous_def?
    expansion.uses_block_arg = uses_block_arg?
    expansion.block_arity = block_arity
    expansion.raises = raises?
    expansion.free_vars = free_vars
    expansion.annotations = annotations
    expansion.special_vars = special_vars
    if owner = self.owner?
      expansion.owner = owner
    end
    expansion.original_name = original_name

    if retain_body
      new_body = [] of ASTNode
      body = self.body.clone

      # Declare variables that are not covered
      args.each_with_index do |arg, index|
        # Skip if the argument is covered by a positional argument
        next if index < args_size && !(splat_index && index > splat_index)

        # Skip if this is the splat index argument
        next if index == splat_index

        # But first check if we already have it in the named arguments
        unless named_args.try &.index(arg.external_name)
          default_value = arg.default_value.not_nil!

          # If the default value is a magic constant we add it to the expanded
          # def and don't declare it (since it's already an argument)
          if default_value.is_a?(MagicConstant)
            expansion.args.push arg.clone
          else
            assign = Assign.new(Var.new(arg.name).at(arg), default_value).at(arg)

            if restriction = arg.restriction
              assign = AssignWithRestriction.new(assign, restriction)
            end

            new_body << assign
          end
        end
      end

      # Splat argument
      if splat_names && splat_index
        tuple_args = [] of ASTNode
        splat_size.times do |i|
          tuple_args << Var.new(splat_names[i]).at(self)
        end
        splat_arg = args[splat_index]
        tuple = TupleLiteral.new(tuple_args).at(splat_arg)
        new_body << Assign.new(Var.new(splat_arg.name).at(splat_arg), tuple).at(splat_arg)
      end

      # Double splat argument
      if double_splat
        named_tuple_entries = [] of NamedTupleLiteral::Entry
        named_args.try &.each_with_index do |named_arg, i|
          # Don't put here regular arguments
          next if args.any? &.external_name.==(named_arg)

          temp_name = named_args_temp_names.not_nil![i]
          named_tuple_entries << NamedTupleLiteral::Entry.new(named_arg, Var.new(temp_name))
        end
        named_tuple = NamedTupleLiteral.new(named_tuple_entries).at(double_splat)
        new_body << Assign.new(Var.new(double_splat.name).at(double_splat), named_tuple).at(double_splat)
      end

      new_body.push body
      expansion.body = Expressions.new(new_body).at(body)
    else
      new_args = [] of ASTNode
      body = [] of ASTNode

      # Append variables that are already covered
      0.upto(args_size - 1) do |index|
        arg = args[index]
        new_args.push Var.new(arg.name)
      end

      # Append default values for those not covered
      args_size.upto(args.size - 1) do |index|
        arg = args[index]

        # But first check if we already have it in the named arguments
        if named_args.try &.index(arg.external_name)
          new_args.push Var.new(arg.name)
        else
          default_value = arg.default_value.not_nil!

          # If the default value is a magic constant we add it to the expanded
          # def, and use that on the forwarded call
          if default_value.is_a?(MagicConstant)
            new_args.push Var.new(arg.name)
            expansion.args.push arg.clone
          else
            body << Assign.new(Var.new(arg.name).at(arg), default_value.clone).at(arg)
            new_args.push Var.new(arg.name).at(arg)
          end
        end
      end

      call = Call.new(name, new_args).at(self)
      call.expansion = true
      body << call

      expansion.body = Expressions.new(body).at(self.body)
    end

    expansion
  end
end
