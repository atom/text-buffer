'use strict'

const setEqual = require('../../src/set-helpers').setEqual

Set.prototype.isEqual = function (other) { // eslint-disable-line no-extend-native
  if (other instanceof Set) {
    return setEqual(this, other)
  } else {
    return undefined
  }
}

Set.prototype.jasmineToString = function () { // eslint-disable-line no-extend-native
  let result = 'Set {'
  let first = true
  this.forEach((element) => {
    if (!first) {
      result += ', '
    }
    result += element.toString()
    return result
  })
  first = false
  return result + '}'
}

let toEqualSet = (expectedItems, customMessage) => {
  let pass = true
  let expectedSet = new Set(expectedItems)
  if (customMessage == null) {
    customMessage = ''
  }

  expectedSet.forEach((item) => {
    if (!this.actual.has(item)) {
      pass = false
      this.message = () => {
        return 'Expected set ' + (formatSet(this.actual)) + ' to have item ' + item + '. ' + customMessage
      }
      return this.message
    }
  })
  this.actual.forEach((item) => {
    if (!expectedSet.has(item)) {
      pass = false
      this.message = () => {
        return 'Expected set ' + (formatSet(this.actual)) + ' not to have item ' + item + '. ' + customMessage
      }
      return this.message
    }
  })
  return pass
}

let formatSet = (set) => {
  return '(' + (setToArray(set).join(' ')) + ')'
}

let setToArray = (set) => {
  let items = []
  set.forEach((item) => {
    return items.push(item)
  })
  return items.sort()
}

// let currentSpecFailed = () => {
//   console.log(jasmine.getEnv())
//   return jasmine
//     .getEnv()
//     .currentSpec
//     .results()
//     .getItems()
//     .some((item) => {
//       return !item.passed()
//     })
// }

module.exports = {toEqualSet, formatSet}
