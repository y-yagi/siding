# frozen_string_literal: true

module Siding
  module BootComponent
    class << self
      def add(*adding_paths)
        adding_paths.flatten.each do |path|
          expanded = File.expand_path(path.to_s)
          paths << expanded unless paths.include?(expanded)
        end
        paths
      end

      def paths = @paths ||= []
      def reset! = @paths = []
    end
  end
end
