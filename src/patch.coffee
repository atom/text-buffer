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

last = (array) -> array[array.length - 1]

class PatchIterator
  constructor: (@patch) ->
    @inputPosition = Point.zero()
    @outputPosition = Point.zero()
    @pathToCurrentLeaf = []
    @descendToLeftmostLeaf(@patch.rootNode)

  next: ->
    if @pathToCurrentLeaf.length > 0
      {node, offset} = last(@pathToCurrentLeaf)
      leaf = node

      value = leaf.content?.slice(offset.column) ? null
      @inputPosition = @inputPosition.traverse(Point.max(Point.zero(), leaf.inputExtent.traversalFrom(offset)))
      @outputPosition = @outputPosition.traverse(leaf.outputExtent.traversalFrom(offset))

      @pathToCurrentLeaf.pop()

      while pathEntry = last(@pathToCurrentLeaf)
        pathEntry.nextChildIndex++
        if nextChild = pathEntry.node.children[pathEntry.nextChildIndex]
          @descendToLeftmostLeaf(nextChild)
          break
        else
          @pathToCurrentLeaf.pop()

      {value, done: false}
    else
      {value: null, done: true}

  seek: (targetOutputPosition) ->
    @pathToCurrentLeaf.length = 0

    targetInputPosition = Point.zero()
    childInputStart = Point.zero()
    childOutputStart = Point.zero()
    nodeOutputStart = Point.zero()

    node = @patch.rootNode

    loop
      offset = targetOutputPosition.traversalFrom(nodeOutputStart)
      pathEntry = {node, offset: offset}
      @pathToCurrentLeaf.push(pathEntry)

      if node.children?
        for child, childIndex in node.children
          childInputEnd = childInputStart.traverse(child.inputExtent)
          childOutputEnd = childOutputStart.traverse(child.outputExtent)

          if childOutputEnd.compare(targetOutputPosition) > 0
            pathEntry.nextChildIndex = childIndex
            nodeOutputStart = childOutputStart
            node = child
            break

          childOutputStart = childOutputEnd
          childInputStart = childInputEnd
          targetInputPosition = targetInputPosition.traverse(child.inputExtent)
      else
        targetInputPosition = targetInputPosition.traverse(Point.min(offset, node.inputExtent))
        break

    @inputPosition = targetInputPosition
    @outputPosition = targetOutputPosition.copy()
    this

  splice: (oldOutputExtent, newOutputExtent, newContent) ->
    pathToNewLeaf = []
    pathIndex = @pathToCurrentLeaf.length - 1

    {node, offset} = @pathToCurrentLeaf[pathIndex]

    @outputPosition = @outputPosition.traverse(newOutputExtent)

    extentToCut = Point.min(Point.zero(), oldOutputExtent.traversalFrom(node.outputExtent.traversalFrom(offset)))
    nextOffset = offset.traverse(oldOutputExtent)

    if node.content?
      @inputPosition = @inputPosition.traverse(Point.min(node.inputExtent, newOutputExtent))
      overshoot = Point.max(Point.zero(), nextOffset.traversalFrom(node.outputExtent))
      node.inputExtent = node.inputExtent.traverse(overshoot)
      undershoot = Point.max(Point.zero(), node.outputExtent.traversalFrom(nextOffset))
      node.outputExtent = offset.traverse(newOutputExtent).traverse(undershoot)

      if node.inputExtent.isZero() and node.outputExtent.isZero()
        node = null
        splitNodes = []
      else
        node.content =
          node.content.slice(0, offset.column) +
          newContent +
          node.content.slice(offset.column + oldOutputExtent.column)
        splitNodes = null
        pathToNewLeaf.unshift({node, offset: nextOffset})
    else
      @inputPosition = @inputPosition.traverse(oldOutputExtent)

      undershoot = node.outputExtent.traversalFrom(nextOffset)
      node = new Leaf(oldOutputExtent, newOutputExtent, newContent)
      splitNodes = [node]
      if offset.isPositive()
        splitNodes.unshift(new Leaf(offset, offset, null))
      if undershoot.isPositive()
        splitNodes.push(new Leaf(undershoot, undershoot, null))
      pathToNewLeaf.unshift({node, offset: newOutputExtent})

    previousChild = node
    pathIndex--

    while pathIndex >= 0
      {node, offset, nextChildIndex} = @pathToCurrentLeaf[pathIndex]

      if splitNodes?
        node.children.splice(nextChildIndex, 1, splitNodes...)
        nextChildIndex += splitNodes.length
        splitNodes = null
      else
        nextChildIndex++

      nextOffset = offset.traverse(oldOutputExtent)
      undershoot = Point.min(Point.zero(), node.outputExtent.traversalFrom(nextOffset))
      node.outputExtent = offset.traverse(oldOutputExtent).traverse(undershoot)

      while extentToCut.isPositive() and nextChildIndex < node.children.length
        child = node.children[nextChildIndex]
        newExtentToCut = extentToCut.traversalFrom(child.outputExtent)
        if newExtentToCut.isPositive()
          node.children.splice(nextChildIndex, 1)
        else
          child.cut(extentToCut)
        extentToCut = newExtentToCut

      if node.children.length > BRANCHING_THRESHOLD
        splitIndex = Math.ceil(node.children.length / BRANCHING_THRESHOLD)
        splitNodes = [new Node(node.children.slice(0, splitIndex)), new Node(node.children.slice(splitIndex))]
        node = if nextChildIndex < splitIndex
          splitNodes[0]
        else
          splitNodes[1]

      pathToNewLeaf.unshift({node, offset: nextOffset, nextChildIndex: node.children.indexOf(previousChild)})
      previousChild = node
      pathIndex--

    if splitNodes?
      @patch.rootNode = new Node(splitNodes)
      node = @patch.rootNode
      pathToNewLeaf.unshift({node, offset: @outputPosition, nextChildIndex: node.children.indexOf(previousChild)})

    @pathToCurrentLeaf = pathToNewLeaf
    lastPathEntry = last(@pathToCurrentLeaf)
    @next() if lastPathEntry.offset.compare(lastPathEntry.node.outputExtent) is 0
    return

  getOutputPosition: ->
    @outputPosition.copy()

  getInputPosition: ->
    @inputPosition.copy()

  descendToLeftmostLeaf: (node) ->
    loop
      pathEntry = {node, offset: Point.zero()}
      @pathToCurrentLeaf.push(pathEntry)
      if node.children?
        pathEntry.nextChildIndex = 0
        node = node.children[0]
      else
        break

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
