require 'coffee-cache'
jasmine.getEnv().addEqualityTester(require('underscore-plus').isEqual)
require('grim').includeDeprecatedAPIs = false

toEqualSet = ->
  compare: (expectedItems, customMessage) ->
    pass = true
    actualSet = this.actual
    expectedSet = new Set(expectedItems)

    expectedSet.forEach (item) ->
      unless actualSet.has(item)
        pass = false
        result.message = -> "Expected set #{formatSet(actualSet)} to have item #{item}. #{customMessage}"

    actualSet.forEach (item) ->
      unless expectedSet.has(item)
        pass = false
        this.message = -> "Expected set #{formatSet(actualSet)} not to have item #{item}. #{customMessage}"

    pass

currentSpecFailed = ->
  jasmine
    .getEnv()
    .currentSpec
    .results()
    .getItems()
    .some (item) -> not item.passed()

module.exports = {toEqualSet, currentSpecFailed}
