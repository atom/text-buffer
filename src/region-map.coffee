Point = require "./point"

module.exports =
class RegionMap
  constructor: ->
    @regions = [{
      content: null
      extent: Point.infinity()
      sourceExtent: Point.infinity()
    }]

  @::[Symbol.iterator] = ->
    new Iterator(this)

class Iterator
  constructor: (@regionMap) ->
    @seek(Point.zero())

  seek: (@position) ->
    position = Point.zero()
    sourcePosition = Point.zero()

    for region, index in @regionMap.regions
      nextPosition = position.traverse(region.extent)
      nextSourcePosition = position.traverse(region.sourceExtent)

      if nextPosition.compare(@position) > 0
        @index = index
        @regionOffset = @position.traversalFrom(position)
        @sourcePosition = Point.min(sourcePosition.traverse(@regionOffset), nextSourcePosition)
        return

      position = nextPosition
      sourcePosition = nextSourcePosition

    # This shouldn't happen because the last region's extent is infinite.
    throw new Error("No region found for position #{@position}")

  next: ->
    if region = @regionMap.regions[@index]
      value = region.content?.slice(@regionOffset.column) ? null

      remainingExtent = region.extent.traversalFrom(@regionOffset)
      remainingSourceExtent = region.sourceExtent.traversalFrom(@regionOffset)

      @position = @position.traverse(remainingExtent)
      if remainingSourceExtent.isPositive()
        @sourcePosition = @sourcePosition.traverse(remainingSourceExtent)

      @index++
      @regionOffset = Point.zero()
      {value, done: false}
    else
      {value: null, done: true}

  splice: (oldExtent, newContent) ->
    unless @regionOffset.isZero()
      @regionMap.regions.splice(@index, 0,
        extent: @regionOffset
        sourceExtent: @regionOffset
        content: @regionMap.regions[@index].content
      )
      @regionOffset = Point.zero()
      @index++

    newExtent = Point(0, newContent.length)
    @regionMap.regions.splice(@index, 0, {
      extent: newExtent
      sourceExtent: oldExtent
      content: newContent
    })
    @index++

    @position = @position.traverse(newExtent)
    @sourcePosition = @sourcePosition.traverse(oldExtent)

  getPosition: ->
    @position

  getSourcePosition: ->
    @sourcePosition
