Point = require "./point"

module.exports =
class RegionMap
  constructor: ->
    @regions = [{
      content: null
      extent: Point.infinity()
    }]

  @::[Symbol.iterator] = ->
    new Iterator(this)

class Iterator
  constructor: (@regionMap) ->
    @seek(Point.zero())

  seek: (@position) ->
    position = Point.zero()

    for region, index in @regionMap.regions
      nextPosition = position.traverse(region.extent)
      if nextPosition.compare(@position) > 0
        @index = index
        @regionOffset = @position.traversalFrom(position)
        return
      position = nextPosition

    # This shouldn't happen because the last region's extent is infinite.
    throw new Error("No region found for position #{@position}")

  next: ->
    if region = @regionMap.regions[@index]
      partialRegion = {
        content: region.content?.slice(@regionOffset.column) ? null
        extent: region.extent.traversalFrom(@regionOffset)
      }
      @position = @position.traverse(partialRegion.extent)
      @index++
      @regionOffset = Point.zero()
      {value: partialRegion, done: false}
    else
      {value: null, done: true}

  splice: (extent, newRegion) ->
    unless @regionOffset.isZero()
      @regionMap.regions.splice(@index, 0, {extent: @regionOffset, content: @regionMap.regions[@index].content})
      @regionOffset = Point.zero()
      @index++

    @regionMap.regions.splice(@index, 0, newRegion)
    @index++

    @position = @position.traverse(newRegion.extent)

  getPosition: ->
    @position
