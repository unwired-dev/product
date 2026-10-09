require 'json'
require 'ripper'

def literal_pod_name(arguments)
  case arguments
  in [:args_add_block, [[:string_literal, [:string_content, [:@tstring_content, name, _]]], *], _]
    name
  else
    nil # Computed names fail the allowlist instead of being evaluated.
  end
end

def declared_pods(node)
  return [] unless node.is_a?(Array)

  pods = case node
  in [:command, [:@ident, 'pod', _], arguments]
    [literal_pod_name(arguments)]
  in [:method_add_arg, [:fcall, [:@ident, 'pod', _]], [:arg_paren, arguments]]
    [literal_pod_name(arguments)]
  in [:command_call, _, _, [:@ident, 'pod', _], arguments]
    [literal_pod_name(arguments)]
  in [:method_add_arg, [:call, _, _, [:@ident, 'pod', _]], [:arg_paren, arguments]]
    [literal_pod_name(arguments)]
  in [:vcall, [:@ident, 'pod', _]]
    [nil]
  else
    []
  end
  pods + node.flat_map { |child| declared_pods(child) }
end

tree = Ripper.sexp(File.read(ARGV.fetch(0)))
abort 'Unable to parse Mac Podfile scope.' unless tree
puts JSON.generate(declared_pods(tree))
