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
      nextSourcePosition = sourcePosition.traverse(region.sourceExtent)

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
    newRegions = []
    startIndex = @index
    startPosition = @position
    startSourcePosition = @sourcePosition

    unless @regionOffset.isZero()
      regionToSplit = @regionMap.regions[@index]
      newRegions.push({
        extent: @regionOffset
        sourceExtent: @regionOffset
        content: regionToSplit.content?.substring(0, @regionOffset.column) ? null
      })

    @seek(@position.traverse(oldExtent))

    sourceExtent = @sourcePosition.traversalFrom(startSourcePosition)
    newExtent = Point(0, newContent.length)
    newRegions.push({
      extent: newExtent
      sourceExtent: sourceExtent
      content: newContent
    })

    regionToSplit = @regionMap.regions[@index]
    newRegions.push({
      extent: regionToSplit.extent.traversalFrom(@regionOffset)
      sourceExtent: Point.max(Point.zero(), regionToSplit.sourceExtent.traversalFrom(@regionOffset))
      content: regionToSplit.content?.slice(@regionOffset.column)
    })

    spliceRegions = []
    lastRegion = null
    for region in newRegions
      if lastRegion?.content? and region.content?
        lastRegion.content += region.content
        lastRegion.sourceExtent = lastRegion.sourceExtent.traverse(region.sourceExtent)
        lastRegion.extent = lastRegion.extent.traverse(region.extent)
      else
        spliceRegions.push(region)
        lastRegion = region

    @regionMap.regions.splice(startIndex, @index - startIndex + 1, spliceRegions...)

    @seek(startPosition.traverse(newExtent))

  getPosition: ->
    @position

  getSourcePosition: ->
    @sourcePosition
