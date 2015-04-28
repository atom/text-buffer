Point = require "./point"
last = (array) -> array[array.length - 1]

BRANCHING_THRESHOLD = 3

class Node
  constructor: (@children) ->
    @calculateExtent()

  splice: (childIndex, splitChildren) ->
    spliceChild = @children[childIndex]

    if splitChildren?
      @children.splice(childIndex, 1, splitChildren...)
      childIndex += splitChildren.indexOf(spliceChild)

    i = childIndex
    while (child = @children[i]) and (nextChild = @children[i + 1])
      if child.merge(nextChild)
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
    {splitNodes, inputOffset, outputOffset, childIndex}

  cut: (extentToCut, cutIndex=0) ->
    inputCut = Point.zero()
    totalExtentToCut = extentToCut
    while extentToCut.isPositive() and (child = @children[cutIndex])
      if extentToCut.compare(child.outputExtent) >= 0
        @children.splice(cutIndex, 1)
        inputCut = inputCut.traverse(child.inputExtent)
        extentToCut = extentToCut.traversalFrom(child.outputExtent)
      else
        result = child.cut(extentToCut, 0)
        inputCut = inputCut.traverse(result.inputCut)
        extentToCut = result.extentToCut
    if cutIndex is 0
      @inputExtent = @inputExtent.traversalFrom(inputCut)
      @outputExtent = @outputExtent.traversalFrom(totalExtentToCut)
    {extentToCut, inputCut}

  merge: (rightNeighbor) ->
    totalChildCount = @children.length + rightNeighbor.children.length
    shouldMerge =
      (totalChildCount <= BRANCHING_THRESHOLD) or
      ((totalChildCount is BRANCHING_THRESHOLD + 1) and
        last(@children).merge(rightNeighbor.children[0]) and
        rightNeighbor.children.shift())

    if shouldMerge
      @inputExtent = @inputExtent.traverse(rightNeighbor.inputExtent)
      @outputExtent = @outputExtent.traverse(rightNeighbor.outputExtent)
      @children.push(rightNeighbor.children...)
      true

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
      #{indent}Node #{@inputExtent} #{@outputExtent}
      #{@children.map((c) -> c.toString(indentLevel + 2)).join("\n")}
    """

class Leaf
  constructor: (@inputExtent, @outputExtent, @content) ->

  splice: (outputOffset, spliceOldExtent, spliceNewExtent, spliceContent) ->
    splitNodes = null
    spliceOldEnd = outputOffset.traverse(spliceOldExtent)
    extentAfterSplice = @outputExtent.traversalFrom(spliceOldEnd).sanitizeNegatives()

    if @content? or spliceNewExtent.isZero()
      @content = @content.slice(0, outputOffset.column) +
        spliceContent +
        @content.slice(spliceOldEnd.column) if @content?
      @outputExtent = outputOffset
        .traverse(spliceNewExtent)
        .traverse(extentAfterSplice)
      outputOffset = outputOffset.traverse(spliceNewExtent)
      inputOffset = Point.min(outputOffset, @inputExtent)

    else
      splitNodes = []
      if outputOffset.isPositive()
        splitNodes.push(new Leaf(outputOffset, outputOffset, null))
        @inputExtent = @inputExtent.traversalFrom(outputOffset).sanitizeNegatives()
      @content = spliceContent
      @outputExtent = spliceNewExtent
      splitNodes.push(this)
      if extentAfterSplice.isPositive()
        splitNodes.push(new Leaf(extentAfterSplice, extentAfterSplice, null))
        @inputExtent = spliceOldExtent
      outputOffset = @outputExtent
      inputOffset = @inputExtent

    {splitNodes, inputOffset, outputOffset}

  cut: (extentToCut) ->
    inputCut = Point.min(extentToCut, @inputExtent)
    @content = @content?.slice(extentToCut.column) ? null
    @outputExtent = @outputExtent.traversalFrom(extentToCut)
    @inputExtent = @inputExtent.traversalFrom(inputCut)
    {inputCut, extentToCut: Point.zero()}

  merge: (rightNeighbor) ->
    shouldMerge =
      (@content? is rightNeighbor.content?) or
      (@inputExtent.isZero() and @outputExtent.isZero()) or
      (rightNeighbor.inputExtent.isZero() and rightNeighbor.outputExtent.isZero())

    if shouldMerge
      @content = null if @outputExtent.isZero()
      rightNeighbor.content = null if rightNeighbor.outputExtent.isZero()
      if @content? and rightNeighbor.content?
        @content = @content + rightNeighbor.content
      @outputExtent = @outputExtent.traverse(rightNeighbor.outputExtent)
      @inputExtent = @inputExtent.traverse(rightNeighbor.inputExtent)
      true

  toString: (indentLevel=0) ->
    indent = ""
    indent += " " for i in [0...indentLevel] by 1

    if @content?
      "#{indent}Leaf #{@inputExtent} #{@outputExtent} #{JSON.stringify(@content)}"
    else
      "#{indent}Leaf #{@inputExtent} #{@outputExtent}"

class PatchIterator
  constructor: (@patch) ->
    @path = []
    @descendToLeftmostLeaf(@patch.rootNode)

  next: ->
    while (entry = last(@path)) and (entry.outputOffset.compare(entry.node.outputExtent) is 0)
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

  splice: (oldOutputExtent, newOutputExtent, newContent) ->
    newPath = []
    splitNodes = null
    extentToCut = null
    previousNode = null

    for {node, outputOffset, childIndex} in @path by -1
      if node instanceof Leaf

        # Determine how far the splice extends beyond this leaf. Subsequent
        # nodes will need to be shrunk or removed to make room for the splice.
        extentToCut = outputOffset
          .traverse(oldOutputExtent)
          .traversalFrom(node.outputExtent)

        # Insert the new content into the leaf.
        {splitNodes, inputOffset, outputOffset} = node.splice(
          outputOffset,
          oldOutputExtent,
          newOutputExtent,
          newContent
        )
      else

        # Shrink or remove any subsequent nodes that fall within the splice,
        # transferring the removed input extent onto the spliced nodes.
        {extentToCut, inputCut} = node.cut(extentToCut, childIndex + 1)
        for entry in newPath
          entry.node.inputExtent = entry.node.inputExtent.traverse(inputCut)

        # If the spliced child node has split, insert the split-off children.
        {splitNodes, inputOffset, outputOffset, childIndex} = node.splice(
          childIndex,
          splitNodes
        )

      previousNode = node
      newPath.unshift({node, inputOffset, outputOffset, childIndex})

    # If the root node has split, create a new root node and add an entry
    # for it at the beginning of the iterator's path.
    if splitNodes?
      node = @patch.rootNode = new Node([previousNode])
      {inputOffset, outputOffset, childIndex} = node.splice(0, splitNodes)
      newPath.unshift({node, inputOffset, outputOffset, childIndex})

    # If the root node's children have all merged, remove the root node.
    while @patch.rootNode.children?.length is 1
      @patch.rootNode = @patch.rootNode.children[0]
      newPath.shift()

    # Adjust the input offset into the leaf node, since its input-extent may have been
    # updated as subsequent nodes within the slice were cut.
    leafEntry = last(newPath)
    leafEntry.inputOffset = Point.max(
      leafEntry.inputOffset,
      Point.min(leafEntry.outputOffset, leafEntry.node.inputExtent)
    )
    @path = newPath
    return

  getOutputPosition: ->
    result = Point.zero()
    for entry in @path
      result = result.traverse(entry.outputOffset)
    result

  getInputPosition: ->
    result = Point.zero()
    for {node, inputOffset, outputOffset} in @path
      if node instanceof Leaf and outputOffset.isEqual(node.outputExtent)
        result = result.traverse(node.inputExtent)
      else
        result = result.traverse(inputOffset)
    result

  descendToLeftmostLeaf: (node) ->
    loop
      entry = {node, outputOffset: Point.zero(), inputOffset: Point.zero(), childIndex: null}
      @path.push(entry)
      if node.children?
        entry.childIndex = 0
        node = node.children[0]
      else
        break

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
