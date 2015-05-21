Point = require "./point"

BRANCHING_THRESHOLD = 3

class Node
  constructor: (@children) ->
    @inputExtent = Point.zero()
    @outputExtent = Point.zero()
    for child in @children
      @inputExtent = @inputExtent.traverse(child.inputExtent)
      @outputExtent = @outputExtent.traverse(child.outputExtent)

  splice: (spliceOutputStart, oldOutputExtent, newOutputExtent, content) ->
    spliceOldOutputEnd = spliceOutputStart.traverse(oldOutputExtent)

    i = 0
    childOutputEnd = Point.zero()
    while i < @children.length
      child = @children[i]
      childOutputStart = childOutputEnd
      childOutputEnd = childOutputStart.traverse(child.outputExtent)

      if extentToCut?
        newExtentToCut = extentToCut.traversalFrom(child.outputExtent)
        if newExtentToCut.isPositive()
          @children.splice(i, 1)
          extentToCut = newExtentToCut
        else
          child.cut(extentToCut)
          break
      else
        if childOutputEnd.compare(spliceOutputStart) > 0
          relativeSpliceOutputStart = spliceOutputStart.traversalFrom(childOutputStart)
          extentToCut = spliceOldOutputEnd.traversalFrom(childOutputEnd)
          if splitNodes = child.splice(relativeSpliceOutputStart, oldOutputExtent, newOutputExtent, content)
            @children.splice(i, 1, splitNodes...)
            i += splitNodes.length
          else
            i++
        else
          i++

    if @children.length > BRANCHING_THRESHOLD
      splitIndex = Math.ceil(@children.length / BRANCHING_THRESHOLD)
      [new Node(@children.slice(0, splitIndex)), new Node(@children.slice(splitIndex))]
    else
      null

  cut: (extentToCut) ->
    @inputExtent = Point.max(Point.zero(), @inputExtent.traversalFrom(extent))
    @outputExtent = @outputExtent.traversalFrom(extent)

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

  mergeChildrenIfNeeded: (i) ->
    if @children[i]?.shouldMergeWith(@children[i + 1])
      @children.splice(i, 2, @children[i].merge(@children[i + 1]))
      true
    else
      false

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

  splice: (outputStart, oldOutputExtent, newOutputExtent, newContent) ->
    oldOutputEnd = outputStart.traverse(oldOutputExtent)
    if @content?
      @inputExtent = @inputExtent
        .traverse(Point.max(Point.zero(), oldOutputEnd.traversalFrom(@outputExtent)))
      @outputExtent = outputStart
        .traverse(newOutputExtent)
        .traverse(Point.max(Point.zero(), @outputExtent.traversalFrom(oldOutputEnd)))
      @content =
        @content.slice(0, outputStart.column) +
        newContent +
        @content.slice(outputStart.column + oldOutputExtent.column)
      return
    else
      splitLeaves = [new Leaf(oldOutputExtent, newOutputExtent, newContent)]
      trailingExtent = @outputExtent.traversalFrom(oldOutputEnd)
      if outputStart.isPositive()
        splitLeaves.unshift(new Leaf(outputStart, outputStart, null))
      if trailingExtent.isPositive()
        splitLeaves.push(new Leaf(@inputExtent.traversalFrom(oldOutputEnd), trailingExtent, null))
      splitLeaves

  cut: (extent) ->
    @outputExtent = @outputExtent.traversalFrom(extent)
    @inputExtent = Point.max(Point.zero(), @inputExtent.traversalFrom(extent))

  getHunks: ->
    [{@inputExtent, @outputExtent, @content}]

  toString: (indentLevel=0) ->
    indent = ""
    indent += " " for i in [0...indentLevel] by 1

    if @content?
      "#{indent}Leaf #{@inputExtent} #{@outputExtent} \"#{@content}\""
    else
      "#{indent}Leaf #{@inputExtent} #{@outputExtent}"

module.exports =
class Patch
  constructor: ->
    @rootNode = new Leaf(Point.infinity(), Point.infinity(), null)

  splice: (outputPosition, oldOutputExtent, newOutputExtent, content) ->
    if splitNodes = @rootNode.splice(outputPosition, oldOutputExtent, newOutputExtent, content)
      @rootNode = new Node(splitNodes)

  toInputPosition: (outputPosition) ->

  toOutputPosition: (inputPosition) ->

  getHunks: ->
    @rootNode.getHunks()

  toString: ->
    result = "[Patch"
    for hunk in @getHunks()
      result += "\n  "
