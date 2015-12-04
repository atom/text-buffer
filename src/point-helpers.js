'use strict'

exports.compare = function (a, b) {
  if (a.row === b.row) {
    return compareNumbers(a.column, b.column)
  } else {
    return compareNumbers(a.row, b.row)
  }
}

function compareNumbers (a, b) {
  if (a < b) {
    return -1
  } else if (a > b) {
    return 1
  } else {
    return 0
  }
}

exports.traverse = function (start, distance) {
  if (distance.row === 0) {
    return {
      row: start.row,
      column: start.column + distance.column
    }
  } else {
    return {
      row: start.row + distance.row,
      column: distance.column
    }
  }
}

exports.traversal = function (end, start) {
  if (end.row === start.row) {
    return {row: 0, column: end.column - start.column}
  } else {
    return {row: end.row - start.row, column: end.column}
  }
}

const NEWLINE_REG_EXP = /\n/g

exports.characterIndexForPoint = function (text, point) {
  let row = point.row
  let column = point.column
  NEWLINE_REG_EXP.lastIndex = 0
  while (row-- > 0) NEWLINE_REG_EXP.exec(text)
  return NEWLINE_REG_EXP.lastIndex + column
}
