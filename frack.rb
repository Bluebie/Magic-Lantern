require 'sourcify'
require 'pp'

# Frack is a little translator to convert ruby in to crappy C
class Frack
  NL = "\n"
  
  # convert a block of simple ruby in to some C we can run!
  def from &code
    @vars = Variabler.new
    sexp = code.to_sexp(strip_enclosure: true)
    sourcecode = statements(sexp)
    pp sexp
    return @vars.sourcecode + NL + sourcecode
  end
  
  # convert an s-expression in to C
  def expression sexp
    return nil if sexp == nil
    #pp sexp
    body = sexp.sexp_body
    case sexp[0]
    # when :block # a collection of things to do!
    #   body.map { |i| convert(i) + NL }.join
    when :iasgn # assign to instance variable
      value = expression( sexp[2] )
      name = @vars.set( sexp[1], value.type )
      "#{name} = (#{value})"
    when :lit, :false, :true, :array # literal values
      literal(sexp)
    when :ivar
      @vars.get(sexp.value)
    when :call # call a 'method' on something
      call(sexp[1], sexp[2], sexp[3].sexp_body)
    when :if # statements resembling ifs
      condition = expression(sexp[1])
      true_code = expression(sexp[2])
      false_code = expression(sexp[3])
      "( ( #{condition} )?( #{true_code} ):( #{false_code} ) )"
    when :colon2 # lookup constants
      if sexp[1][0] == :const and sexp[1][1] == :Math
        case sexp[2]
        when :PI
          Value.typed CTypeFloat, Math::PI.inspect
        end
      end
    when :not # the !something operator
      Value.typed CTypeBoolean, "!(#{ expression(sexp.value) })"
    else
      raise "IDK how to handle this S-expression: #{ sexp.inspect }!"
    end
  end
  
  # convert in to statements on lines
  def statements sexp
    return nil if sexp == nil
    case sexp[0]
    when :lit, :false, :true, :array, :hash
      raise "Line doesn't do anything"
    when :block
      sexp.sexp_body.map { |i| statements(i) }.join()
    when :if
      condition = expression sexp[1]
      true_code = indent statements sexp[2]
      false_code = indent statements sexp[3]
      if true_code and false_code
        "if (#{condition}) {\n#{true_code}} else {\n#{false_code}}\n"
      elsif true_code
        "if (#{condition}) {\n#{true_code}}\n"
      elsif false_code
        "if (!(#{condition})) {\n#{false_code}}\n"
      end
    when :while
      condition = expression sexp[1]
      code = indent statements sexp[2]
      if sexp[3] # is precondition?
        "while (#{condition}) {\n#{code}}\n"
      else
        "{\n#{code}} while (#{condition})\n"
      end
    else
      "#{ expression(sexp) };\n"
    end
  end
  
  # get the C type of an S-Expression literal
  def type_of literal
    case literal.sexp_type
    when :true, :false
      'unsigned char'
    when :array
      "#{ type_of(literal.sexp_body.first) }[#{ literal.sexp_body.count }]"
    when :lit
      case literal.sexp_body.first.class.name
      when 'NilClass', 'Fixnum', 'Bignum'
        'signed long'
      when 'Float'
        'float'
      else
        raise "Unsupported type #{literal.sexp_body.first.class.name} used: #{literal.sexp_body.first}"
      end
    end
  end
  
  # Get the value of an S-Expression literal
  CTypeInt = 'signed long'
  CTypeFloat = 'float'
  CTypeBoolean = 'unsigned char'
  def literal sexp
    case sexp.sexp_type
    when :lit
      case sexp.value.class.name
      when 'Bignum', 'Fixnum'
        Value.typed CTypeInt, sexp.value.inspect
      when 'Float'
        Value.typed CTypeFloat, "#{ sexp.value.inspect }f"
      else
        raise "Couldn't convert literal #{ sexp.value } of type #{ sexp.value.class.name }"
      end
    when :array
      values = sexp.sexp_body.map { |i| expression(i) }
      type = "#{ values.first.type }[#{ values.count }]"
      raise "Array contains different kinds of objects" unless values.map { |i| i.type }.uniq.count == 1
      Value.typed type, "{ #{ values.join(', ') } }"
    when :true
      Value.typed CTypeBoolean, '1'
    when :false
      Value.typed CTypeBoolean, '0'
    end
  end
  
  # return what a method call should look like
  def call thing, method, args
    case method
    when :+, :-, :/, :*, :%, :<, :>, :<=, :>=, :==
      subject = expression(thing)
      Value.typed subject.type, "(#{ subject }) #{method} (#{ expression(args.first) })"
    when :floor, :ceil
      Value.typed CTypeInt, "#{method}(#{ expression(thing) })"
    when :[]
      callee = expression(thing)
      index = expression(args.first)
      raise "Used [] operator on object which is not an Array" unless callee.type.include? '['
      raise "Used [] operator with too many index arguments" if args.length > 1
      raise "Used [] operator without an index" if args.length == 0
      raise "Used [] operator with a non-integer index" unless index.type == CTypeInt
      Value.typed callee.type.split('[').first, "#{callee}[#{index}]"
    when :[]=
      callee = expression(thing)
      index = expression(args[0])
      value = expression(args[1])
      raise "Used []= operator on object which is not an Array" unless callee.type.include? '['
      raise "Used []= operator with too many index arguments" if args.length > 2
      raise "Used []= operator needs both index and new value" if args.length < 2
      raise "Used []= operator with a non-integer index" unless index.type == CTypeInt
      Value.typed value, "#{callee}[#{index}] = #{value}"
    #when :truncate
    #  "((signed long) #{ expression(thing) })"
    end
  end
  
  def indent lines
    return nil if lines == nil
    lines.to_s.split(/\n/).map { |line| "  #{line}\n" }.join
  end
  
  class Variabler
    def initialize; @vars = {}; end
    
    # use this to get a reference to a variable when wanting to get it's value
    def get named
      raise VariableError, "Used variable '#{named}' without setting it to something first" unless @vars.key? named
      refurbish(named)
    end
    
    # use this to get a reference to a variable to assign to it - type is required!
    def set named, type
      raise VariableError, "Tried to set variable #{named} before initializing with a constant" unless type or @vars[named]
      if @vars.key? named
        raise VariableError, "Variable '#{named}' was previously set to a #{ @vars[named] } but is now being set to a #{type}" if @vars[named] != type
        return refurbish(named)
      else
        @vars[named] = type
        return refurbish(named)
      end
    end
    
    # takes in a ruby variable name and Cifies it
    def refurbish variable_name
      Value.typed @vars[variable_name], variable_name.to_s.sub(/^\@/, '') #.sub(/^\$/, '')
    end
    
    def sourcecode
      @vars.map { |name, type| "#{type} #{ refurbish(name) };" + NL }.join
    end
    
    # for errors caused by using variables in an incompatible way
    class VariableError < StandardError; end
  end
  
  class Value < String
    attr_accessor :type
    def self.typed type, string
      newb = self.new(string)
      newb.type = type
      return newb
    end
  end
end

puts "/*=== Converted Code ===*/"
puts( Frack.new.from {
  @angle = 0.0
  @foo = true
  
  @angle += 0.005
  
  while @foo
    @foo = false
  end
  
  @angle -= Math::PI if @angle > Math::PI
} )

# color do
#   @angle += timestep
#   @angle -= Math::PI * 2 if @angle > Math::PI * 2
#   glow 1.0, 0.0, 0.0
# end

