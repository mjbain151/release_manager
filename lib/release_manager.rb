require "release_manager/version"
require "release_manager/module_deployer"
class String
  def colorize(color_code)
    "\e[#{color_code}m#{self}\e[0m"
  end

  def red
    colorize(31)
  end

  def green
    colorize(32)
  end

def yellow
    colorize(33)
  end
end
module ReleaseManager

end
