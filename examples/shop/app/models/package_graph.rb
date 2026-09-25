# The module dependency graph, read from the package.yml files packwerk enforces, and laid
# out by layer: a module sits one layer above the highest module it depends on. A dependency
# on another module's published-event package alone is drawn as an event edge.
#
# Two dependencies are left out of the drawing to keep it readable. The console itself -- the
# host application -- depends on every module. And every module depends on Platform, which
# is drawn as the foundation they all stand on rather than as an arrow from each.
class PackageGraph
  Node = Data.define(:name, :layer, :x, :y, :width)
  Edge = Data.define(:from, :to, :events_only)

  FOUNDATION = "Platform"
  WIDTH = 960
  NODE_WIDTH = 132
  NODE_HEIGHT = 40
  LAYER_GAP = 96

  attr_reader :nodes, :edges

  def self.load(root)
    packages = {}
    Dir[root.join("engines/*/package.yml")].sort.each do |path|
      packages[File.basename(File.dirname(path)).camelize] = YAML.load_file(path).fetch("dependencies", [])
    end
    new(packages)
  end

  def initialize(packages)
    dependencies = packages.flat_map do |name, paths|
      paths.group_by { |path| module_of(path) }.except(name).map do |target, target_paths|
        Edge.new(from: name, to: target, events_only: target_paths.all? { |path| path.end_with?("/events") })
      end
    end
    layers = {}
    layer_of = ->(name) { layers[name] ||= 1 + (dependencies.select { |edge| edge.from == name }.map { |edge| layer_of.(edge.to) }.max || -1) }
    packages.each_key(&layer_of)
    @edges = dependencies.reject { |edge| edge.to == FOUNDATION }
    @nodes = place(layers)
  end

  def height = (@nodes.map(&:layer).max + 1) * LAYER_GAP
  def node(name) = @nodes.find { |node| node.name == name }

  private
    def module_of(path) = path.split("/")[1].to_s.camelize

    # Highest layer at the top and the foundation across the whole width at the bottom. The
    # layers are placed from the bottom up, each ordered by where its dependencies already sit,
    # so that arrows cross as little as possible.
    def place(layers)
      top = layers.values.max
      placed = {}
      layers.group_by(&:last).sort.each do |layer, members|
        names = members.map(&:first).sort_by { |name| [ mean_target_x(name, placed), name ] }
        names.each_with_index do |name, index|
          y = (top - layer) * LAYER_GAP + 12
          placed[name] =
            if name == FOUNDATION
              Node.new(name: name, layer: layer, x: 24, y: y, width: WIDTH - 48)
            else
              Node.new(name: name, layer: layer, x: (WIDTH * (index + 1) / (names.size + 1)) - NODE_WIDTH / 2, y: y, width: NODE_WIDTH)
            end
        end
      end
      placed.values
    end

    def mean_target_x(name, placed)
      targets = @edges.select { |edge| edge.from == name }.filter_map { |edge| placed[edge.to] }
      targets.empty? ? WIDTH / 2 : targets.sum { |node| node.x + node.width / 2 } / targets.size
    end
end
