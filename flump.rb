require 'sourcify'

class Flump
  
  class SimpleFunction
    def initialize(offset, name, &proc)
      @offset = offset
      @name = name
      @proc = proc
    end
    
    # convert to machine code, with a given pointer offset
    def to_machine_code
      output = []
      output.push 0 # where the return value goes
      count_args.times do |i|
        output.push i+1 # include a spot for each byte argument
      end
      
      output.push *to_machine_code_body
      output.push *Flump.asm(:load_r0, 0)
      output.push *Flump.asm(:jump_r0_eq_0, 88) # caller should overwrite this address
      return output
    end
    
    # return code offset (where to jump to in call)
    def code_address; @offset + 1 + count_args; end
    
    # return address of return value
    def ret_value_addr; @offset; end
    
    # offset for return address to be written - is the last byte 
    def ret_address_store_addr; @offset + length; end
    
    # length of entire function definition
    def length; to_machine_code.length; end
    
    # get the code to call this function
    def call program, call_offset, *args
      raise "#{@name} expects #{count_args} but was called with #{args.length} arguments" unless args.length == count_args
      
      output = []
      #output.push *Flump.asm(:r0_to_addr, 254)
      output.push *Flump.asm(:r1_to_addr, 255)
      output.push *Flump.asm(:load_r0, 0)
      
      # figure out where to jump back to after call is done
      # there are 3 two byte instructions including this one until after the jump, so add those also
      output.push *Flump.asm(:load_r1, call_offset + output.length + 6)
      output.push *Flump.asm(:write_r1, ret_address_store_addr) # store return address to function definition
      output.push *Flump.asm(:jump_r0_eq_0, code_address) # jump in to function execution
      # after function is done, it jumps back here and restore register and get return value
      output.push *Flump.asm(:swap_r0_with_addr, ret_value_addr)
      output.push *Flump.asm(:swap_r1_with_addr, 255)
      return output
    end
    
    # returns number of arguments
    def count_args; proc.arity; end
  end
  
  # maintains index of variables stored at end of memory
  class VariableSpace
    def initialize
      @vars = []
    end
    
    def reference name
      @vars.push name unless @vars.include? name
      255 - @vars.index(name)
    end
    alias_method :[], :reference
  end
end