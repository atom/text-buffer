Point = require "./point"

BRANCHING_THRESHOLD = 3

class Node
  constructor: (@children) ->
    @inputExtent = Point.zero()
    @outputExtent = Point.zero()
    for child in @children
      @inputExtent = @inputExtent.traverse(child.inputExtent)
      @outputExtent = @outputExtent.traverse(child.outputExtent)

  cut: (extentToCut) ->
    @inputExtent = Point.max(Point.zero(), @inputExtent.traversalFrom(extentToCut))
    @outputExtent = @outputExtent.traversalFrom(extentToCut)

    i = 0
    while i < @children.length
      child = @children[i]

      newExtentToCut = extentToCut.traversalFrom(child.outputExtent)
      if newExtentToCut.isPositive()
        @children.splice(i, 1)
        extentToCut = newExtentToCut
      else
        child.cut(extentToCut)
        break

  getHunks: ->
    result = []
    for child in @children
      result = result.concat(child.getHunks())
    result

  toString: (indentLevel=0) ->
    indent = ""
    indent += " " for i in [0...indentLevel] by 1

    """
      #{indent}Node #{@inputExtent} #{@outputExtent}
      #{@children.map((c) -> c.toString(indentLevel + 2)).join("\n")}
    """

class Leaf
  constructor: (@inputExtent, @outputExtent, @content) ->

  cut: (extent) ->
    @outputExtent = @outputExtent.traversalFrom(extent)
    @inputExtent = Point.max(Point.zero(), @inputExtent.traversalFrom(extent))

  getHunks: ->
    [{@inputExtent, @outputExtent, @content}]

  toString: (indentLevel=0) ->
    indent = ""
    indent += " " for i in [0...indentLevel] by 1

    if @content?
      "#{indent}Leaf #{@inputExtent} #{@outputExtent} #{JSON.stringify(@content)}"
    else
      "#{indent}Leaf #{@inputExtent} #{@outputExtent}"

class PatchIterator
  constructor: (@patch) ->
    @inputPosition = Point.zero()
    @outputPosition = Point.zero()
    @nodeStack = []
    @descend(@patch.rootNode)

  next: ->
    if @leaf?
      value = @leaf.content?.slice(@leafOffset.column) ? null
      @inputPosition = @inputPosition.traverse(Point.max(Point.zero(), @leaf.inputExtent.traversalFrom(@leafOffset)))
      @outputPosition = @outputPosition.traverse(@leaf.outputExtent.traversalFrom(@leafOffset))
      @leaf = null

      while parent = @nodeStack[@nodeStack.length - 1]
        parent.childIndex++
        if nextChild = parent.node.children[parent.childIndex]
          @descend(nextChild)
          break
        else
          @nodeStack.pop()

      {value, done: false}
    else
      {value: null, done: true}

  seek: (outputPosition) ->
    childInputStart = Point.zero()
    childOutputStart = Point.zero()

    node = @patch.rootNode
    @nodeStack.length = 0

    while node.children?
      for child, childIndex in node.children
        childInputEnd = childInputStart.traverse(child.inputExtent)
        childOutputEnd = childOutputStart.traverse(child.outputExtent)

        if childOutputEnd.compare(outputPosition) > 0
          foundChild = true
          @nodeStack.push({node, childIndex})
          node = child
          break

        childOutputStart = childOutputEnd
        childInputStart = childInputEnd

    @leaf = node
    @leafOffset = outputPosition.traversalFrom(childOutputStart)
    @inputPosition = childInputStart.traverse(Point.min(@leafOffset, @leaf.inputExtent))
    @outputPosition = outputPosition.copy()
    this

  splice: (oldOutputExtent, newOutputExtent, newContent) ->
    extentToCut = oldOutputExtent.traversalFrom(@leaf.outputExtent.traversalFrom(@leafOffset))
    newNodeStack = []

    oldOutputEnd = @leafOffset.traverse(oldOutputExtent)
    if @leaf.content?
      @leaf.inputExtent = @leaf.inputExtent
        .traverse(Point.max(Point.zero(), oldOutputEnd.traversalFrom(@leaf.outputExtent)))
      @leaf.outputExtent = @leafOffset
        .traverse(newOutputExtent)
        .traverse(Point.max(Point.zero(), @leaf.outputExtent.traversalFrom(oldOutputEnd)))
      @leaf.content =
        @leaf.content.slice(0, @leafOffset.column) +
        newContent +
        @leaf.content.slice(@leafOffset.column + oldOutputExtent.column)
      splitNodes = null
    else
      splicedInLeaf = new Leaf(oldOutputExtent, newOutputExtent, newContent)
      splitNodes = [splicedInLeaf]
      trailingExtent = @leaf.outputExtent.traversalFrom(oldOutputEnd)
      if @leafOffset.isPositive()
        splitNodes.unshift(new Leaf(@leafOffset, @leafOffset, null))
        @leafOffset = Point.zero()
      if trailingExtent.isPositive()
        splitNodes.push(new Leaf(@leaf.inputExtent.traversalFrom(oldOutputEnd), trailingExtent, null))
      @leaf = splicedInLeaf

    previousChild = @leaf
    for {node, childIndex} in @nodeStack by -1
      if splitNodes?
        node.children.splice(childIndex, 1, splitNodes...)
        childIndex += splitNodes.length
        splitNodes = null
      else
        childIndex++

      while extentToCut.isPositive() and childIndex < node.children.length
        child = node.children[childIndex]
        newExtentToCut = extentToCut.traversalFrom(child.outputExtent)
        if newExtentToCut.isPositive()
          node.children.splice(childIndex, 1)
        else
          child.cut(extentToCut)
        extentToCut = newExtentToCut

      if node.children.length > BRANCHING_THRESHOLD
        splitIndex = Math.ceil(node.children.length / BRANCHING_THRESHOLD)
        splitNodes = [new Node(node.children.slice(0, splitIndex)), new Node(node.children.slice(splitIndex))]
        node = if childIndex < splitIndex
          splitNodes[0]
        else
          splitNodes[1]

      newNodeStack.unshift({node, childIndex: node.children.indexOf(previousChild)})
      previousChild = node

    if splitNodes?
      @patch.rootNode = new Node(splitNodes)
      node = @patch.rootNode
      newNodeStack.unshift({node, childIndex: node.children.indexOf(previousChild)})

    @nodeStack = newNodeStack
    @leafOffset = @leafOffset.traverse(newOutputExtent)
    @outputPosition = @outputPosition.traverse(newOutputExtent)
    @inputPosition = @inputPosition.traverse(Point.min(@leaf.inputExtent, newOutputExtent))
    @next() if @leafOffset.compare(@leaf.outputExtent) is 0
    return

  getOutputPosition: ->
    @outputPosition.copy()

  getInputPosition: ->
    @inputPosition.copy()

  descend: (node) ->
    while node.children?
      @nodeStack.push({node, childIndex: 0})
      node = node.children[0]
    @leaf = node
    @leafOffset = Point.zero()

module.exports =
class Patch
  constructor: ->
    @rootNode = new Leaf(Point.infinity(), Point.infinity(), null)

  splice: (spliceOutputStart, oldOutputExtent, newOutputExtent, content) ->
    iterator = @buildIterator()
    iterator.seek(spliceOutputStart)
    iterator.splice(oldOutputExtent, newOutputExtent, content)

  buildIterator: ->
    new PatchIterator(this)

  toInputPosition: (outputPosition) ->

  toOutputPosition: (inputPosition) ->

  getHunks: ->
    @rootNode.getHunks()

  toString: ->
    result = "[Patch"
    for hunk in @getHunks()
      result += "\n  "
