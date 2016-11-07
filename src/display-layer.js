const Patch = require('atom-patch/build/Release/atom_patch')
const {Emitter} = require('event-kit')
const Point = require('./point')
const Range = require('./range')
const EmptyDecorationLayer = require('./empty-decoration-layer')
const {traverse, traversal, compare: comparePoints, isEqual} = require('./point-helpers')
// const {normalizePatchChanges} = require('./helpers')

module.exports =
class DisplayLayer {
  constructor (id, buffer, settings) {
    this.id = id
    this.buffer = buffer
    this.foldIdCounter = 1
    this.spatialIndex = new Patch()
    this.screenLineLengths = []
    this.textDecorationLayer = new EmptyDecorationLayer()
    this.emitter = new Emitter()

    this.invisibles = {}
    this.tabLength = 4
    this.softWrapColumn = Infinity
    this.softWrapHangingIndent = 0
    this.showIndentGuides = false
    this.ratioForCharacter = () => 1
    this.isWrapBoundary = isWordStart
    this.foldCharacter = '⋯'
    this.atomicSoftTabs = true
    this.reset(settings)
  }

  reset (params) {
    if (params.hasOwnProperty('tabLength')) this.tabLength = params.tabLength
    if (params.hasOwnProperty('invisibles')) this.invisibles = params.invisibles
    if (params.hasOwnProperty('showIndentGuides')) this.showIndentGuides = params.showIndentGuides
    if (params.hasOwnProperty('softWrapColumn')) this.softWrapColumn = params.softWrapColumn
    if (params.hasOwnProperty('softWrapHangingIndent')) this.softWrapHangingIndent = params.softWrapHangingIndent
    if (params.hasOwnProperty('ratioForCharacter')) this.ratioForCharacter = params.ratioForCharacter
    if (params.hasOwnProperty('isWrapBoundary')) this.isWrapBoundary = params.isWrapBoundary
    if (params.hasOwnProperty('foldCharacter')) this.foldCharacter = params.foldCharacter
    if (params.hasOwnProperty('atomicSoftTabs')) this.atomicSoftTabs = params.atomicSoftTabs

    this.eolInvisibles = {
      '\r': this.invisibles.cr,
      '\n': this.invisibles.eol,
      '\r\n': this.invisibles.cr + this.invisibles.eol
    }

    this.emitter.emit('did-reset')

    this.populateSpatialIndex()
  }

  translateBufferPosition (bufferPosition, options) {
    bufferPosition = this.buffer.clipPosition(bufferPosition)
    let hunk = this.spatialIndex.hunkForOldPosition(bufferPosition)
    if (hunk) {
      if (comparePoints(bufferPosition, hunk.oldEnd) < 0) {
        if (comparePoints(hunk.oldStart, hunk.oldEnd) === 0) { // Soft wrap
          if (options && options.clipDirection === 'forward') {
            return Point.fromObject(hunk.newEnd)
          } else {
            return Point.fromObject(hunk.newStart).traverse(Point(0, -1))
          }
        } else { // Hard tab sequence
          if (comparePoints(hunk.oldStart, bufferPosition) === 0) {
            return Point.fromObject(hunk.newStart)
          } else {
            const tabStopBeforeHunk = hunk.newStart.column - hunk.newStart.column % this.tabLength
            const tabCount = bufferPosition.column - hunk.oldStart.column
            const screenColumn = tabStopBeforeHunk + tabCount * this.tabLength
            return Point(hunk.newStart.row, screenColumn)
          }
        }
      } else {
        return traverse(hunk.newEnd, traversal(bufferPosition, hunk.oldEnd))
      }
    } else {
      return Point.fromObject(bufferPosition)
    }
  }

  translateScreenPosition (screenPosition, options) {
    const clipDirection = options && options.clipDirection || 'closest'
    screenPosition = this.constrainScreenPosition(screenPosition, options)
    let hunk = this.spatialIndex.hunkForNewPosition(screenPosition)
    if (hunk) {
      if (comparePoints(screenPosition, hunk.newEnd) < 0) {
        if (comparePoints(hunk.oldStart, hunk.oldEnd) === 0) { // Soft wrap
          if (clipDirection === 'backward' || clipDirection === 'closest' && isEqual(hunk.newStart, screenPosition)) {
            return traverse(hunk.oldStart, Point(0, -1))
          } else {
            return Point.fromObject(hunk.oldStart)
          }
        } else { // Hard tab sequence
          if (comparePoints(hunk.newStart, screenPosition) === 0) {
            return Point.fromObject(hunk.oldStart)
          }

          const tabStopBeforeHunk = hunk.newStart.column - hunk.newStart.column % this.tabLength
          const targetColumn = screenPosition.column
          const tabStopBeforeTarget = targetColumn - targetColumn % this.tabLength
          const tabStopAfterTarget = tabStopBeforeTarget + this.tabLength

          let clippedTargetColumn
          if (targetColumn === tabStopBeforeTarget) {
            clippedTargetColumn = tabStopBeforeTarget
          } else {
            switch (clipDirection) {
              case 'backward':
                clippedTargetColumn = tabStopBeforeTarget
                break
              case 'forward':
                clippedTargetColumn = tabStopAfterTarget
                break
              case 'closest':
                clippedTargetColumn =
                  (targetColumn - tabStopBeforeTarget > tabStopAfterTarget - targetColumn)
                    ? tabStopAfterTarget
                    : tabStopBeforeTarget
                break
            }
          }

          return Point(
            hunk.oldStart.row,
            hunk.oldStart.column + (clippedTargetColumn - tabStopBeforeHunk) / this.tabLength
          )
        }
      } else {
        return traverse(hunk.oldEnd, traversal(screenPosition, hunk.newEnd))
      }
    } else {
      return Point.fromObject(screenPosition)
    }
  }

  clipScreenPosition (screenPosition, options) {
    const clipDirection = options && options.clipDirection || 'closest'
    screenPosition = this.constrainScreenPosition(screenPosition, options)
    let hunk = this.spatialIndex.hunkForNewPosition(screenPosition)
    if (hunk) {
      if (comparePoints(hunk.oldStart, hunk.oldEnd) === 0) { // Soft wrap
        if (clipDirection === 'backward' || clipDirection === 'closest' && isEqual(hunk.newStart, screenPosition)) {
          return traverse(hunk.newStart, Point(0, -1))
        } else {
          return Point.fromObject(hunk.newEnd)
        }
      } else { // Hard tab
        if (comparePoints(hunk.newStart, screenPosition) < 0 &&
            comparePoints(screenPosition, hunk.newEnd) < 0) {
          const column = screenPosition.column
          const tabStopBeforeColumn = column - column % this.tabLength
          const tabStopAfterColumn = tabStopBeforeColumn + this.tabLength

          let clippedColumn
          if (column === tabStopBeforeColumn) {
            clippedColumn = tabStopBeforeColumn
          } else {
            switch (options && options.clipDirection) {
              case 'backward':
                clippedColumn = Math.max(tabStopBeforeColumn, hunk.newStart.column)
                break
              case 'forward':
                clippedColumn = tabStopAfterColumn
                break
              default:
                clippedColumn =
                  (column - tabStopBeforeColumn > tabStopAfterColumn - column)
                    ? tabStopAfterColumn
                    : Math.max(tabStopBeforeColumn, hunk.newStart.column)
                break
            }
          }

          return Point(hunk.newStart.row, clippedColumn)
        }
      }
    }
    return Point.fromObject(screenPosition)
  }

  constrainScreenPosition (screenPosition, options) {
    screenPosition = Point.fromObject(screenPosition)
    let {row, column} = screenPosition

    if (row < 0) {
      return new Point(0, 0)
    }

    const maxRow = this.screenLineLengths.length - 1
    if (row > maxRow) {
      return new Point(maxRow, 0)
    }

    if (column < 0) {
      return new Point(row, 0)
    }

    const maxColumn = this.screenLineLengths[row]
    if (column > maxColumn) {
      if (options && options.clipDirection === 'forward' && row < maxRow) {
        return new Point(row + 1, 0)
      } else {
        return new Point(row, maxColumn)
      }
    }

    return screenPosition
  }

  getText () {
    return this.getScreenLines().map((line) => line.lineText).join('\n')
  }

  getLastScreenRow () {
    return this.screenLineLengths.length - 1
  }

  getScreenLines (screenStartRow = 0, screenEndRow = this.getLastScreenRow() + 1) {
    let screenLines = []
    let screenRow = screenStartRow
    let {row: bufferRow} = this.translateScreenPosition(Point(screenStartRow, 0))
    while (screenRow < screenEndRow) {
      let screenLine = ''
      let screenColumn = 0
      let bufferLine = this.buffer.lineForRow(bufferRow)
      let bufferColumn = 0

      while (bufferColumn < bufferLine.length) {
        const character = bufferLine[bufferColumn]
        if (character === '\t') {
          const distanceToNextTabStop = this.tabLength - (screenColumn % this.tabLength)
          screenLine += ' '.repeat(distanceToNextTabStop)
          screenColumn += distanceToNextTabStop
        } else {
          screenLine += character
          screenColumn += 1
        }
        bufferColumn++
      }

      screenLines.push({lineText: screenLine})
      screenRow++
      bufferRow++
    }

    return screenLines
  }

  populateSpatialIndex () {
    const endBufferRow = this.buffer.getLineCount()

    let bufferRow = 0
    let screenRow = 0
    let bufferColumn = 0
    let screenColumn = 0
    let tabSequenceLength = 0
    let tabSequenceStartScreenColumn = -1
    let screenLineWidth = 0
    let lastWrapBoundaryScreenColumn = 0
    let lastWrapBoundaryScreenLineWidth = 0
    let firstNonWhitespaceScreenColumn

    while (bufferRow < endBufferRow) {
      const bufferLine = this.buffer.lineForRow(bufferRow)
      const bufferLineLength = bufferLine.length

      while (bufferColumn <= bufferLineLength) {
        const previousCharacter = bufferLine[bufferColumn - 1]
        const character = bufferLine[bufferColumn]

        // Assign indentation level for line if necessary
        if (firstNonWhitespaceScreenColumn == null && character !== ' ' && character !== '\t') {
          firstNonWhitespaceScreenColumn = screenColumn
        }

        // Record this position if it is a viable soft wrap boundary
        if (this.isWrapBoundary(previousCharacter, character)) {
          lastWrapBoundaryScreenColumn = screenColumn
          lastWrapBoundaryScreenLineWidth = screenLineWidth
        }

        // Determine the on-screen width of the character for soft-wrap calculations
        let characterWidth
        if (character === '\t') {
          const distanceToNextTabStop = this.tabLength - (screenColumn % this.tabLength)
          characterWidth = this.ratioForCharacter(' ') * distanceToNextTabStop
        } else {
          characterWidth = this.ratioForCharacter(character)
        }

        // Insert a soft line break if necessary
        if (screenLineWidth + characterWidth > this.softWrapColumn) {
          const indentLength = firstNonWhitespaceScreenColumn + this.softWrapHangingIndent
          const wrapColumn = lastWrapBoundaryScreenColumn || screenColumn
          const wrapWidth = lastWrapBoundaryScreenLineWidth || screenLineWidth
          this.spatialIndex.splice(
            Point(screenRow, wrapColumn),
            Point.ZERO,
            Point(1, indentLength)
          )
          this.screenLineLengths.push(wrapColumn)
          screenRow++
          screenColumn = indentLength + (screenColumn - wrapColumn)
          screenLineWidth = (indentLength * this.ratioForCharacter(' ')) + (screenLineWidth - wrapWidth)
          lastWrapBoundaryScreenColumn = 0
          lastWrapBoundaryScreenLineWidth = 0
        }

        screenLineWidth += characterWidth

        if (character === '\t') {
          if (tabSequenceLength === 0) {
            tabSequenceStartScreenColumn = screenColumn
          }
          tabSequenceLength++
          const distanceToNextTabStop = this.tabLength - (screenColumn % this.tabLength)
          screenColumn += distanceToNextTabStop
          screenLineWidth += this.ratioForCharacter(' ') * distanceToNextTabStop
        } else {
          if (tabSequenceLength > 0) {
            this.spatialIndex.splice(
              Point(screenRow, tabSequenceStartScreenColumn),
              Point(0, tabSequenceLength),
              Point(0, screenColumn - tabSequenceStartScreenColumn)
            )
            tabSequenceLength = 0
            tabSequenceStartScreenColumn = -1
          }
          screenColumn++
        }

        bufferColumn++
      }

      this.screenLineLengths.push(screenColumn - 1)

      bufferRow++
      bufferColumn = 0

      screenRow++
      screenColumn = 0
    }
  }
}

function isWordStart (previousCharacter, character) {
  return (previousCharacter === ' ' || previousCharacter === '\t') &&
    (character !== ' ' && character !== '\t')
}
