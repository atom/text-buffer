require 'coffee-cache'

currentSpecResult = null
jasmine.getEnv().addReporter specStarted: (result) -> currentSpecResult = result
currentSpecFailed = -> currentSpecResult.failedExpectations.length > 0

expectMapsToSource = (layer, sourcePosition, position, clip) ->
  expect(layer.toSourcePosition(position, clip)).toEqual(sourcePosition)

expectMapsFromSource = (layer, sourcePosition, position, clip) ->
  expect(layer.fromSourcePosition(sourcePosition, clip)).toEqual(position)

expectMapsSymmetrically = (layer, sourcePosition, position) ->
  expectMapsToSource(layer, sourcePosition, position)
  expectMapsFromSource(layer, sourcePosition, position)

toEqualSet = ->
  compare: (actualSet, expectedItems, customMessage) ->
    result = {pass: true, message: ""}
    expectedSet = new Set(expectedItems)

    expectedSet.forEach (item) ->
      unless actualSet.has(item)
        result.pass = false
        result.message = "Expected set #{formatSet(actualSet)} to have item #{item}."

    actualSet.forEach (item) ->
      unless expectedSet.has(item)
        result.pass = false
        result.message = "Expected set #{formatSet(actualSet)} not to have item #{item}."

    result.message += " " + customMessage if customMessage?
    result

formatSet = (set) ->
  "(#{setToArray(set).join(' ')})"

setToArray = (set) ->
  items = []
  set.forEach (item) -> items.push(item)
  items.sort()

module.exports = {currentSpecFailed, expectMapsToSource, expectMapsFromSource, expectMapsSymmetrically, toEqualSet}
