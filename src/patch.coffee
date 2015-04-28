Point = require "./point"

BRANCHING_THRESHOLD = 3

class Node
  constructor: (@children) ->
    @calculateExtent()

  splice: (childIndex, newChildren, extentToCut) ->
    oldChild = @children[childIndex]

    if newChildren?
      @children.splice(childIndex, 1, newChildren...)
      childIndex = @children.indexOf(oldChild)

    if previousChild = @children[childIndex - 1]
      if previousChild.shouldMergeRightNeighbor(@children[childIndex])
        @children[childIndex].mergeLeftNeighbor(previousChild)
        @children.splice(childIndex - 1, 1)
        childIndex--

    i = childIndex
    while i < @children.length - 1
      child = @children[i]
      nextChild = @children[i + 1]
      if child.shouldMergeRightNeighbor(nextChild)
        child.mergeRightNeighbor(nextChild)
        @children.splice(i + 1, 1)
      else
        i++

    splitIndex = Math.ceil(@children.length / BRANCHING_THRESHOLD)
    if splitIndex > 1
      if childIndex < splitIndex
        splitNodes = [this, new Node(@children.splice(splitIndex))]
      else
        splitNodes = [new Node(@children.splice(0, splitIndex)), this]
        childIndex -= splitIndex

    {inputOffset, outputOffset} = @calculateExtent(childIndex)
    {splitNodes, inputOffset, outputOffset, extentToCut, childIndex}

  cut: (extentToCut, cutIndex=0) ->
    originalExtentToCut = extentToCut

    inputCut = Point.zero()
    while (child = @children[cutIndex]) and extentToCut.isPositive()
      if extentToCut.compare(child.outputExtent) >= 0
        @children.splice(cutIndex, 1)
        inputCut = inputCut.traverse(child.inputExtent)
        extentToCut = extentToCut.traversalFrom(child.outputExtent)
      else
        {extentToCut, inputCut: childInputCut} = child.cut(extentToCut, 0)
        inputCut = inputCut.traverse(childInputCut)

    if cutIndex is 0
      @inputExtent = @inputExtent.traversalFrom(inputCut)
      @outputExtent = @outputExtent.traversalFrom(originalExtentToCut).sanitizeNegatives()

    {extentToCut, inputCut}

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

  mergeLeftNeighbor: (leftNeighbor) ->
    leftNeighbor.mergeRightNeighbor(this)
    {@children, @inputExtent, @outputExtent} = leftNeighbor

  mergeRightNeighbor: (rightNeighbor) ->
    if last(@children).shouldMergeRightNeighbor(rightNeighbor.children[0])
      last(@children).mergeRightNeighbor(rightNeighbor.children[0])
      rightNeighbor.children.shift()
    @outputExtent = @outputExtent.traverse(rightNeighbor.outputExtent)
    @inputExtent = @inputExtent.traverse(rightNeighbor.inputExtent)
    @children.push(rightNeighbor.children...)

  shouldMergeRightNeighbor: (rightNeighbor) ->
    newChildCount = @children.length + rightNeighbor.children.length
    if @children[@children.length - 1].shouldMergeRightNeighbor(rightNeighbor.children[0])
      newChildCount--
    newChildCount <= BRANCHING_THRESHOLD

  toString: (indentLevel=0) ->
    indent = ""
    indent += " " for i in [0...indentLevel] by 1

    """
      #{indent}Node #{@inputExtent} #{@outputExtent}
      #{@children.map((c) -> c.toString(indentLevel + 2)).join("\n")}
    """

class Leaf
  constructor: (@inputExtent, @outputExtent, @content) ->

  splice: (outputOffset, spliceOldExtent, spliceNewExtent, spliceContent) ->
    spliceOldEnd = outputOffset.traverse(spliceOldExtent)
    extentAfterSplice = @outputExtent.traversalFrom(spliceOldEnd).sanitizeNegatives()

    if @content? or spliceContent is ""
      @content = @content.slice(0, outputOffset.column) +
        spliceContent +
        @content.slice(spliceOldEnd.column) if @content?
      @outputExtent = outputOffset
        .traverse(spliceNewExtent)
        .traverse(extentAfterSplice)

      splitNodes = null
      outputOffset = outputOffset.traverse(spliceNewExtent)
      inputOffset = Point.min(outputOffset, @inputExtent)
    else
      splitNodes = []
      if outputOffset.isPositive()
        splitNodes.push(new Leaf(outputOffset, outputOffset, null))
        @inputExtent = @inputExtent.traversalFrom(outputOffset).sanitizeNegatives()
      splitNodes.push(this)
      if extentAfterSplice.isPositive()
        splitNodes.push(new Leaf(extentAfterSplice, extentAfterSplice, null))
        @inputExtent = spliceOldExtent

      @content = spliceContent if spliceContent.length > 0
      @outputExtent = spliceNewExtent
      outputOffset = @outputExtent
      inputOffset = Point.min(outputOffset, @inputExtent)

    {splitNodes, inputOffset, outputOffset}

  cut: (extentToCut) ->
    @content = @content?.slice(extentToCut.column) ? null
    @outputExtent = @outputExtent.traversalFrom(extentToCut)
    if extentToCut.compare(@inputExtent) >= 0
      inputCut = @inputExtent
      @inputExtent = Point.zero()
    else
      inputCut = extentToCut
      @inputExtent = @inputExtent.traversalFrom(extentToCut)
    {inputCut, extentToCut: Point.zero()}

  mergeLeftNeighbor: (leftNeighbor) ->
    leftNeighbor.mergeRightNeighbor(this)
    {@content, @outputExtent, @inputExtent} = leftNeighbor

  mergeRightNeighbor: (rightNeighbor) ->
    if @outputExtent.isZero()
      @content = null
    @content = @content + rightNeighbor.content if @content? and rightNeighbor.content?
    @outputExtent = @outputExtent.traverse(rightNeighbor.outputExtent)
    @inputExtent = @inputExtent.traverse(rightNeighbor.inputExtent)

  shouldMergeRightNeighbor: (rightNeighbor) ->
    (@inputExtent.isZero() and @outputExtent.isZero()) or
      (rightNeighbor.inputExtent.isZero() and rightNeighbor.outputExtent.isZero()) or
      (@content? is rightNeighbor.content?)

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
    @stack = []
    @descendToLeftmostLeaf(@patch.rootNode)

  toString: ->
    "[PatchIterator\n" +
      @stack
        .map ({node, inputOffset, outputOffset, childIndex}) ->
          "  inputOffset:#{inputOffset}, outputOffset:#{outputOffset}, childIndex:#{childIndex}"
        .join("\n") + "]"

  next: ->
    while (entry = last(@stack)) and (entry.outputOffset.compare(entry.node.outputExtent) is 0)
      @stack.pop()
      if parentEntry = last(@stack)
        parentEntry.childIndex++
        parentEntry.inputOffset = parentEntry.inputOffset.traverse(entry.inputOffset)
        parentEntry.outputOffset = parentEntry.outputOffset.traverse(entry.outputOffset)
        if nextChild = parentEntry.node.children[parentEntry.childIndex]
          @descendToLeftmostLeaf(nextChild)
          entry = last(@stack)
      else
        @stack.push(entry)
        return {value: null, done: true}

    value = entry.node.content?.slice(entry.outputOffset.column) ? null
    entry.outputOffset = entry.node.outputExtent
    entry.inputOffset = entry.node.inputExtent
    {value, done: false}

  seek: (targetOutputOffset) ->
    @stack.length = 0

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
            @stack.push({node, childIndex, inputOffset, outputOffset})
            targetOutputOffset = targetOutputOffset.traversalFrom(childOutputStart)
            node = child
            break
      else
        inputOffset = Point.min(targetOutputOffset, node.inputExtent)
        outputOffset = targetOutputOffset
        childIndex = null
        @stack.push({node, inputOffset, outputOffset, childIndex})
        node = null

    this

  splice: (oldOutputExtent, newOutputExtent, newContent) ->
    newStack = []
    splitNodes = null
    extentToCut = null
    previousNode = null

    for {node, outputOffset, childIndex} in @stack by -1
      if node instanceof Leaf
        extentToCut = outputOffset
          .traverse(oldOutputExtent)
          .traversalFrom(node.outputExtent)
          .sanitizeNegatives()

        {splitNodes, inputOffset, outputOffset} =
          node.splice(outputOffset, oldOutputExtent, newOutputExtent, newContent)
      else
        if extentToCut.isPositive()
          {extentToCut, inputCut} = node.cut(extentToCut, childIndex + 1)
          for newEntry, i in newStack
            newEntry.node.inputExtent = newEntry.node.inputExtent.traverse(inputCut)

        {splitNodes, inputOffset, outputOffset, childIndex} =
          node.splice(childIndex, splitNodes, extentToCut)

      newStack.unshift({node, inputOffset, outputOffset, childIndex})
      previousNode = node

    if splitNodes?
      node = new Node([previousNode])
      {inputOffset, outputOffset, childIndex} = node.splice(0, splitNodes, Point.zero())
      newStack.unshift({node, inputOffset, outputOffset, childIndex})
      @patch.rootNode = node

    @stack = newStack

    while @patch.rootNode.children?.length is 1
      @patch.rootNode = @patch.rootNode.children[0]
      @stack.shift()

    leafEntry = last(@stack)
    leafEntry.inputOffset = Point.min(leafEntry.outputOffset, leafEntry.node.inputExtent)

    return

  getOutputPosition: ->
    result = Point.zero()
    for entry in @stack
      result = result.traverse(entry.outputOffset)
    result

  getInputPosition: ->
    result = Point.zero()
    for {node, inputOffset, outputOffset} in @stack
      if node instanceof Leaf and outputOffset.isEqual(node.outputExtent)
        result = result.traverse(node.inputExtent)
      else
        result = result.traverse(inputOffset)
    result

  descendToLeftmostLeaf: (node) ->
    while node
      entry = {node, outputOffset: Point.zero(), inputOffset: Point.zero(), childIndex: null}
      @stack.push(entry)
      if node.children?
        entry.childIndex = 0
        node = node.children[0]
      else
        node = null

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
