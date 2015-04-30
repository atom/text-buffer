Point = require "./point"
last = (array) -> array[array.length - 1]
isEmpty = (node) -> node.inputExtent.isZero() and node.outputExtent.isZero()

BRANCHING_THRESHOLD = 3

class Node
  constructor: (@children) ->
    @calculateExtent()

  splice: (childIndex, splitChildren) ->
    spliceChild = @children[childIndex]
    leftMergeIndex = rightMergeIndex = childIndex

    if splitChildren?
      @children.splice(childIndex, 1, splitChildren...)
      childIndex += splitChildren.indexOf(spliceChild)
      rightMergeIndex += splitChildren.length - 1

    if leftNeighbor = @children[leftMergeIndex - 1]
      leftNeighbor.merge(@children[leftMergeIndex])
      if isEmpty(@children[leftMergeIndex])
        @children[leftMergeIndex].assign(leftNeighbor)
        @children.splice(leftMergeIndex - 1, 1)
        childIndex--
        rightMergeIndex--

    if rightNeighbor = @children[rightMergeIndex + 1]
      @children[rightMergeIndex].merge(rightNeighbor)
      if isEmpty(rightNeighbor)
        @children.splice(rightMergeIndex + 1, 1)

    splitIndex = Math.ceil(@children.length / BRANCHING_THRESHOLD)
    if splitIndex > 1
      if childIndex < splitIndex
        splitNodes = [this, new Node(@children.splice(splitIndex))]
      else
        splitNodes = [new Node(@children.splice(0, splitIndex)), this]
        childIndex -= splitIndex

    {inputOffset, outputOffset} = @calculateExtent(childIndex)
    {splitNodes, inputOffset, outputOffset, childIndex}

  merge: (rightNeighbor) ->
    childMerge = last(@children)?.merge(rightNeighbor.children[0])
    rightNeighbor.children.shift() if isEmpty(rightNeighbor.children[0])
    if @children.length + rightNeighbor.children.length <= BRANCHING_THRESHOLD
      @inputExtent = @inputExtent.traverse(rightNeighbor.inputExtent)
      @outputExtent = @outputExtent.traverse(rightNeighbor.outputExtent)
      @children.push(rightNeighbor.children...)
      result = {inputExtent: rightNeighbor.inputExtent, outputExtent: rightNeighbor.outputExtent}
      rightNeighbor.inputExtent = rightNeighbor.outputExtent = Point.zero()
      result
    else if childMerge?
      @inputExtent = @inputExtent.traverse(childMerge.inputExtent)
      @outputExtent = @outputExtent.traverse(childMerge.outputExtent)
      rightNeighbor.inputExtent = rightNeighbor.inputExtent.traversalFrom(childMerge.inputExtent)
      rightNeighbor.outputExtent = rightNeighbor.outputExtent.traversalFrom(childMerge.outputExtent)
      childMerge

  assign: ({@inputExtent, @outputExtent, @children}) ->

  calculateExtent: (childIndex) ->
    result = {inputOffset: null, outputOffset: null}
    @inputExtent = Point.zero()
    @outputExtent = Point.zero()
    for child, i in @children
      if i is childIndex
        result.inputOffset = @inputExtent
        result.outputOffset = @outputExtent
      @inputExtent = @inputExtent.traverse(child.inputExtent)
      @outputExtent = @outputExtent.traverse(child.outputExtent)
    result

  toString: (indentLevel=0) ->
    indent = ""
    indent += " " for i in [0...indentLevel] by 1

    """
      #{indent}[Node #{@inputExtent} #{@outputExtent}]
      #{@children.map((c) -> c.toString(indentLevel + 2)).join("\n")}
    """

class Leaf
  constructor: (@inputExtent, @outputExtent, @content) ->

  insert: (inputOffset, outputOffset, newInputExtent, newOutputExtent, newContent) ->
    inputExtentAfterOffset = @inputExtent.traversalFrom(inputOffset)
    outputExtentAfterOffset = @outputExtent.traversalFrom(outputOffset)

    if @content?
      @inputExtent = inputOffset
        .traverse(newInputExtent)
        .traverse(inputExtentAfterOffset)
      @outputExtent = outputOffset
        .traverse(newOutputExtent)
        .traverse(outputExtentAfterOffset)
      @content = @content.slice(0, outputOffset.column) +
        newContent +
        @content.slice(outputOffset.column)
      inputOffset = inputOffset.traverse(newInputExtent)
      outputOffset = outputOffset.traverse(newOutputExtent)

    else if newInputExtent.isPositive() or newOutputExtent.isPositive()
      splitNodes = []
      if outputOffset.isPositive()
        splitNodes.push(new Leaf(inputOffset, outputOffset, null))
      @inputExtent = newInputExtent
      @outputExtent = newOutputExtent
      @content = newContent
      splitNodes.push(this)
      if outputExtentAfterOffset.isPositive()
        splitNodes.push(new Leaf(inputExtentAfterOffset, outputExtentAfterOffset, null))
      inputOffset = @inputExtent
      outputOffset = @outputExtent

    {splitNodes, inputOffset, outputOffset}

  merge: (rightNeighbor) ->
    if (@content? is rightNeighbor.content?) or isEmpty(this) or isEmpty(rightNeighbor)
      @outputExtent = @outputExtent.traverse(rightNeighbor.outputExtent)
      @inputExtent = @inputExtent.traverse(rightNeighbor.inputExtent)
      @content = (@content ? "") + (rightNeighbor.content ? "")
      @content = null if @content is "" and @outputExtent.isPositive()
      result = {inputExtent: rightNeighbor.inputExtent, outputExtent: rightNeighbor.outputExtent}
      rightNeighbor.inputExtent = rightNeighbor.outputExtent = Point.zero()
      result

  assign: ({@inputExtent, @outputExtent, @content}) ->

  toString: (indentLevel=0) ->
    indent = ""
    indent += " " for i in [0...indentLevel] by 1

    if @content?
      "#{indent}[Leaf #{@inputExtent} #{@outputExtent} #{JSON.stringify(@content)}]"
    else
      "#{indent}[Leaf #{@inputExtent} #{@outputExtent}]"

class PatchIterator
  constructor: (@patch, @path) ->
    unless @path?
      @path = []
      @descendToLeftmostLeaf(@patch.rootNode)

  next: ->
    while ((entry = last(@path)) and
            entry.inputOffset.isEqual(entry.node.inputExtent) and
            entry.outputOffset.isEqual(entry.node.outputExtent))
      @path.pop()
      if parentEntry = last(@path)
        parentEntry.childIndex++
        parentEntry.inputOffset = parentEntry.inputOffset.traverse(entry.inputOffset)
        parentEntry.outputOffset = parentEntry.outputOffset.traverse(entry.outputOffset)
        if nextChild = parentEntry.node.children[parentEntry.childIndex]
          @descendToLeftmostLeaf(nextChild)
          entry = last(@path)
      else
        @path.push(entry)
        return {value: null, done: true}

    value = entry.node.content?.slice(entry.outputOffset.column) ? null
    entry.outputOffset = entry.node.outputExtent
    entry.inputOffset = entry.node.inputExtent
    {value, done: false}

  seek: (targetOutputOffset) ->
    @path.length = 0

    childInputStart = Point.zero()
    childOutputStart = Point.zero()

    node = @patch.rootNode
    while node
      if node.children?
        childInputEnd = Point.zero()
        childOutputEnd = Point.zero()
        for child, childIndex in node.children
          childInputStart = childInputEnd
          childOutputStart = childOutputEnd
          childInputEnd = childInputStart.traverse(child.inputExtent)
          childOutputEnd = childOutputStart.traverse(child.outputExtent)
          if childOutputEnd.compare(targetOutputOffset) >= 0
            inputOffset = childInputStart
            outputOffset = childOutputStart
            @path.push({node, childIndex, inputOffset, outputOffset})
            targetOutputOffset = targetOutputOffset.traversalFrom(childOutputStart)
            node = child
            break
      else
        inputOffset = Point.min(targetOutputOffset, node.inputExtent)
        outputOffset = targetOutputOffset
        childIndex = null
        @path.push({node, inputOffset, outputOffset, childIndex})
        node = null

    this

  splice: (oldOutputExtent, newExtent, newContent) ->
    rightEdge = @copy().seek(@getOutputPosition().traverse(oldOutputExtent))
    oldInputExtent = rightEdge.getInputPosition().traversalFrom(@getInputPosition())
    @deleteUntil(rightEdge)
    @insert(oldInputExtent, newExtent, newContent)

  getOutputPosition: ->
    result = Point.zero()
    for entry in @path
      result = result.traverse(entry.outputOffset)
    result

  getInputPosition: ->
    result = Point.zero()
    for {node, inputOffset, outputOffset} in @path
      result = result.traverse(inputOffset)
    result

  copy: ->
    new PatchIterator(@patch, @path.slice())

  descendToLeftmostLeaf: (node) ->
    loop
      entry = {node, outputOffset: Point.zero(), inputOffset: Point.zero(), childIndex: null}
      @path.push(entry)
      if node.children?
        entry.childIndex = 0
        node = node.children[0]
      else
        break

  deleteUntil: (rightIterator) ->
    meetingIndex = null

    # Delete content to the right of the left iterator.
    totalInputOffset = Point.zero()
    totalOutputOffset = Point.zero()
    for {node, inputOffset, outputOffset, childIndex}, i in @path by -1
      if node is rightIterator.path[i].node
        meetingIndex = i
        break
      if node.content?
        node.content = node.content.slice(0, outputOffset.column)
      else if node.children?
        node.children.splice(childIndex + 1)
      totalInputOffset = inputOffset.traverse(totalInputOffset)
      totalOutputOffset = outputOffset.traverse(totalOutputOffset)
      node.inputExtent = totalInputOffset
      node.outputExtent = totalOutputOffset

    # Delete content to the left of the right iterator.
    totalInputOffset = Point.zero()
    totalOutputOffset = Point.zero()
    for {node, inputOffset, outputOffset, childIndex}, i in rightIterator.path by -1
      if i is meetingIndex
        break
      if node.content?
        node.content = node.content.slice(outputOffset.column)
      else if node.children?
        node.children.splice(childIndex, 1) if isEmpty(node.children[childIndex])
        node.children.splice(0, childIndex)
      totalInputOffset = inputOffset.traverse(totalInputOffset)
      totalOutputOffset = outputOffset.traverse(totalOutputOffset)
      node.inputExtent = node.inputExtent.traversalFrom(totalInputOffset)
      node.outputExtent = node.outputExtent.traversalFrom(totalOutputOffset)

    # Delete content between the two iterators in the same node.
    left = @path[meetingIndex]
    right = rightIterator.path[meetingIndex]
    {node} = left
    node.outputExtent = left.outputOffset.traverse(node.outputExtent.traversalFrom(right.outputOffset))
    node.inputExtent = left.inputOffset.traverse(node.inputExtent.traversalFrom(right.inputOffset))
    if node.content?
      node.content =
        node.content.slice(0, left.outputOffset.column) +
        node.content.slice(right.outputOffset.column)
    else if node.children?
      spliceIndex = left.childIndex + 1
      node.children.splice(right.childIndex, 1) if isEmpty(node.children[right.childIndex])
      node.children.splice(spliceIndex, right.childIndex - spliceIndex)
    this

  insert: (newInputExtent, newOutputExtent, newContent) ->
    newPath = []
    splitNodes = null
    for {node, inputOffset, outputOffset, childIndex} in @path by -1
      if node instanceof Leaf
        {splitNodes, inputOffset, outputOffset} = node.insert(
          inputOffset,
          outputOffset,
          newInputExtent,
          newOutputExtent,
          newContent
        )
      else
        {splitNodes, inputOffset, outputOffset, childIndex} = node.splice(
          childIndex,
          splitNodes
        )
      newPath.unshift({node, inputOffset, outputOffset, childIndex})

    if splitNodes?
      node = @patch.rootNode = new Node([node])
      {inputOffset, outputOffset, childIndex} = node.splice(0, splitNodes)
      newPath.unshift({node, inputOffset, outputOffset, childIndex})

    while @patch.rootNode.children?.length is 1
      @patch.rootNode = @patch.rootNode.children[0]
      newPath.shift()

    @path = newPath
    this

  toString: ->
    entries = for {node, inputOffset, outputOffset, childIndex} in @path
      "  {inputOffset:#{inputOffset}, outputOffset:#{outputOffset}, childIndex:#{childIndex}}"
    "[PatchIterator\n#{entries.join("\n")}]"

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
