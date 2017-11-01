const fs = require('fs-plus')
const path = require('path')
const {Writable, Transform} = require('stream')
const temp = require('temp')
const {Disposable} = require('event-kit')
const Point = require('../src/point')
const Range = require('../src/range')
const TextBuffer = require('../src/text-buffer')
const {TextBuffer: NativeTextBuffer} = require('superstring')
const fsAdmin = require('fs-admin')
const pathwatcher = require('pathwatcher')

process.on('unhandledRejection', console.error)

describe('TextBuffer IO', () => {
  let buffer, buffer2

  afterEach(() => {
    if (buffer) buffer.destroy()
    if (buffer2) buffer2.destroy()

    const watched = pathwatcher.getWatchedPaths()
    if (watched.length > 0) {
      for (const watchedPath of watched) {
        console.error(`WARNING: leaked file watcher for path ${watchedPath}`)
      }
      pathwatcher.closeAllWatchers()
    }
  })

  describe('.load', () => {
    it('resolves with a buffer containing the given file\'s text', (done) => {
      const filePath = temp.openSync('atom').path
      fs.writeFileSync(filePath, 'abc')

      TextBuffer.load(filePath).then((buf) => {
        buffer = buf
        expect(buffer.getText()).toBe('abc')
        expect(buffer.isModified()).toBe(false)
        expect(buffer.undo()).toBe(false)
        expect(buffer.getText()).toBe('abc')
        done()
      })
    })

    it('resolves with an empty buffer if there is no file at the given path', (done) => {
      const filePath = 'does-not-exist.txt'
      TextBuffer.load(filePath).then((buf) => {
        buffer = buf
        expect(buffer.getText()).toBe('')
        expect(buffer.isModified()).toBe(true)
        expect(buffer.undo()).toBe(false)
        expect(buffer.getText()).toBe('')
        done()
      })
    })

    it('rejects if the given path is a directory', (done) => {
      const dirPath = temp.mkdirSync('atom')
      TextBuffer.load(dirPath).then(() => {
        expect('Did not fail with EISDIR').toBeUndefined()
      }, (err) => {
        expect(err.code).toBe(process.platform === 'win32' ? 'EACCES' : 'EISDIR')
      }).then(done, done)
    })

    it('optionally rejects with an ENOENT if there is no file at the given path', (done) => {
      const filePath = 'does-not-exist.txt'
      TextBuffer.load(filePath, {mustExist: true}).then(() => {
        expect('Did not fail with mustExist: true').toBeUndefined()
      }, (err) => {
        expect(err.code).toBe('ENOENT')
      }).then(done, done)
    })

    describe('when a custom File object is given in place of the file path', () => {
      it('loads the buffer using the file\s createReadStream method', (done) => {
        const filePath = temp.openSync('atom').path
        fs.writeFileSync(filePath, 'abc\ndef')

        TextBuffer.load(new ReverseCaseFile(filePath)).then((buf) => {
          buffer = buf
          expect(buffer.getText()).toBe('ABC\nDEF')
          expect(buffer.isModified()).toBe(false)
          done()
        })
      })
    })
  })

  describe('.loadSync', () => {
    it('returns a buffer containing the given file\'s text', () => {
      const filePath = temp.openSync('atom').path
      fs.writeFileSync(filePath, 'abc')

      buffer = TextBuffer.loadSync(filePath)
      expect(buffer.getText()).toBe('abc')
      expect(buffer.isModified()).toBe(false)
    })

    it('returns an empty buffer if the file does not exist', () => {
      buffer = TextBuffer.loadSync('/this/does/not/exist')
      expect(buffer.getText()).toBe('')
    })

    it('throws EISDIR if the path is a directory', () => {
      const dirPath = temp.mkdirSync('atom')
      try {
        TextBuffer.loadSync(dirPath)
        expect('Did not fail with EISDIR').toBeUndefined()
      } catch (e) {
        expect(e.code).toBe(process.platform === 'win32' ? 'EACCES' : 'EISDIR')
      }
    })

    it('optionally throws ENOENT if there is no file at the given path', () => {
      try {
        TextBuffer.loadSync('/does-not-exist.txt', {mustExist: true})
        expect('Did not fail with mustExist: true').toBeUndefined()
      } catch (e) {
        expect(e.code).toBe('ENOENT')
      }
    })
  })

  describe('.reload', () => {
    let filePath

    beforeEach((done) => {
      filePath = temp.openSync('atom').path
      fs.writeFileSync(filePath, 'abcdefg')
      TextBuffer.load(filePath).then((result) => {
        buffer = result
        done()
      })
    })

    it('it updates the buffer even if it is modified', (done) => {
      buffer.delete([[0, 0], [0, 2]])
      expect(buffer.getText()).toBe('cdefg')

      const marker = buffer.markRange([[0, 3], [0, 4]])

      fs.writeFileSync(filePath, '123abcdefg', 'utf8')

      const events = []
      buffer.onWillReload(() => events.push('will-reload'))
      buffer.onDidReload(() => events.push('did-reload'))

      buffer.reload().then(() => {
        expect(events).toEqual(['will-reload', 'did-reload'])
        expect(buffer.getText()).toBe('123abcdefg')
        expect(marker.getRange()).toEqual(Range(Point(0, 8), Point(0, 9)))

        buffer.undo()
        expect(buffer.getText()).toBe('cdefg')
        expect(marker.getRange()).toEqual(Range(Point(0, 3), Point(0, 4)))
        done()
      })
    })

    it('notifies decoration layers and display layers of the change', (done) => {
      fs.writeFileSync(filePath, 'abcdefghijk', 'utf8')

      const events = []

      const displayLayer = buffer.addDisplayLayer()
      displayLayer.onDidChange((event) => events.push(['display-layer', event]))

      buffer.registerTextDecorationLayer({
        bufferDidChange ({oldRange, newRange}) { events.push(['decoration-layer', {oldRange, newRange}]) }
      })

      buffer.reload().then(() => {
        expect(events).toEqual([
          ['decoration-layer', {oldRange: Range(Point(0, 7), Point(0, 7)), newRange: Range(Point(0, 7), Point(0, 11))}],
          ['display-layer', [{oldRange: Range(Point(0, 0), Point(1, 0)), newRange: Range(Point(0, 0), Point(1, 0))}]]
        ])
        done()
      })
    })

    it('clears the contents of the buffer when the file doesn\t exist', (done) => {
      buffer.delete([[0, 0], [0, 2]])

      const events = []
      buffer.onWillReload(() => events.push('will-reload'))
      buffer.onDidReload(() => events.push('did-reload'))

      buffer.setPath('does-not-exist')
      buffer.reload().then(() => {
        expect(events).toEqual(['will-reload', 'did-reload'])
        expect(buffer.getText()).toBe('')
        expect(buffer.isModified()).toBe(true)

        buffer.undo()
        expect(buffer.getText()).toBe('cdefg')
        expect(buffer.isModified()).toBe(true)
        done()
      })
    })

    it('emits reload events even if nothing has changed', (done) => {
      const events = []
      buffer.onWillReload((event) => events.push('will-reload'))
      buffer.onDidReload((event) => events.push('did-reload'))
      buffer.reload().then(() => {
        expect(events).toEqual(['will-reload', 'did-reload'])
        done()
      })
    })

    it('gracefully handles edits performed in onDidChange listeners that are called on reload', (done) => {
      fs.writeFileSync(filePath, 'abcdXefg', 'utf8')

      {
        const subscription = buffer.onDidChange(({changes}) => {
          subscription.dispose()
          expect(changes.length).toBe(1)
          expect(changes[0].oldText).toBe('')
          expect(changes[0].newText).toBe('X')
          buffer.setText('')
        })
      }

      {
        const subscription = buffer.onDidStopChanging(({changes}) => {
          subscription.dispose()

          expect(changes.length).toBe(1)
          expect(changes[0].oldText).toBe('abcdefg')
          expect(changes[0].newText).toBe('')

          expect(buffer.getText()).toBe('')

          buffer.undo()
          expect(buffer.getText()).toBe('abcdXefg')

          buffer.undo()
          expect(buffer.getText()).toBe('abcdefg')

          done()
        })
      }

      buffer.reload()
    })
  })

  describe('.save', () => {
    let filePath
    let tempDir

    beforeEach(() => {
      tempDir = temp.mkdirSync()
      filePath = path.join(tempDir, 'temp.txt')
      fs.writeFileSync(filePath, '')
      buffer = new TextBuffer()
      buffer.setPath(filePath)
    })

    it('saves the contents of the buffer to the path', (done) => {
      buffer.setText('Buffer contents')
      buffer.save().then(() => {
        expect(fs.readFileSync(filePath, 'utf8')).toEqual('Buffer contents')
        expect(buffer.undo()).toBe(true)
        expect(buffer.getText()).toBe('')
        done()
      })
    })

    it('does not emit a change event', (done) => {
      buffer.setText('Buffer contents')
      expect(buffer.isModified()).toBe(true)

      const changeEvents = []
      buffer.onWillChange(() => changeEvents.push(['will-change']))
      buffer.onDidChange((event) => changeEvents.push(['did-change', event]))

      buffer.save().then(() => {
        expect(buffer.isModified()).toBe(false)

        setTimeout(() => {
          expect(changeEvents).toEqual([])
          done()
        }, 250)
      })
    })

    it('does not emit a conflict event due to the save', (done) => {
      const events = []
      buffer.onDidConflict((event) => events.push(event))

      buffer.setText('Buffer contents')
      buffer.save()

      // Modify the file after the save has been asynchronously initiated
      buffer.onDidSave(() => buffer.append('!'))

      const subscription = buffer.file.onDidChange(() => setTimeout(() => {
        subscription.dispose()
        expect(events.length).toBe(0)
        done()
      }, buffer.fileChangeDelay))
    })

    it('does not emit a reload event due to the save', (done) => {
      const events = []
      buffer.onWillReload((event) => events.push(event))
      buffer.onDidReload((event) => events.push(event))

      buffer.setText('Buffer contents')
      buffer.save()

      const subscription = buffer.file.onDidChange(() => {
        setTimeout(() => {
          subscription.dispose()
          expect(events.length).toBe(0)
          done()
        }, buffer.fileChangeDelay + 100)
      })
    })

    it('notifies ::onWillSave and ::onDidSave observers', (done) => {
      const events = []
      buffer.onWillSave((event) => events.push([
        'will-save',
        event,
        fs.readFileSync(filePath, 'utf8')
      ]))
      buffer.onDidSave((event) => events.push([
        'did-save',
        event,
        fs.readFileSync(filePath, 'utf8')
      ]))

      buffer.setText('Buffer contents')
      buffer.save().then(() => {
        const path = buffer.getPath()
        expect(events).toEqual([
          ['will-save', {path}, ''],
          ['did-save', {path}, 'Buffer contents']
        ])
        done()
      })
    })

    it('waits for any promises returned by ::onWillSave observers', (done) => {
      buffer.onWillSave(() => new Promise((resolve) => {
        setTimeout(() => {
          buffer.append(' - updated')
          resolve()
        }, 50)
      }))

      buffer.setText('Buffer contents')
      buffer.save().then(() => {
        expect(fs.readFileSync(filePath, 'utf8')).toBe('Buffer contents - updated')
        done()
      })
    })

    describe('when the buffer is destroyed before the save completes', () => {
      it('saves the current contents of the buffer to the path', (done) => {
        buffer.setText('hello\n')
        buffer.save().then(() => {
          expect(buffer.getText()).toBe('')
          expect(fs.readFileSync(filePath, 'utf8')).toBe('hello\n')
          done()
        })
        buffer.destroy()
      })
    })

    describe('when a conflict is created', () => {
      beforeEach((done) => {
        buffer.setText('a')
        buffer.save().then(() => {
          buffer.setText('ab')
          buffer.onDidConflict(done)
          fs.writeFileSync(buffer.getPath(), 'c')
        })
      })

      it('no longer reports being in conflict when the buffer is saved again', (done) => {
        expect(buffer.isInConflict()).toBe(true)
        buffer.save().then(() => {
          expect(buffer.isInConflict()).toBe(false)
          done()
        })
      })
    })

    describe('when the buffer has no path', () => {
      it('throws an exception', () => {
        buffer2 = new TextBuffer()
        buffer2.setText('hi')
        expect(() => buffer2.save()).toThrowError()
      })
    })

    describe('when the buffer is backed by a custom File object instead of a path', () => {
      beforeEach(() => {
        buffer.destroy()
        buffer = new TextBuffer()
        buffer.setFile(new ReverseCaseFile(filePath))
      })

      it('saves the contents of the buffer to the given file', (done) => {
        buffer.setText('abc DEF ghi JKL\n'.repeat(10 * 1024))
        buffer.save().then(() => {
          expect(fs.readFileSync(filePath, 'utf8')).toBe('ABC def GHI jkl\n'.repeat(10 * 1024))
          expect(buffer.isModified()).toBe(false)
          done()
        })
      })

      it('does not emit a conflict event due to the save', (done) => {
        const events = []
        buffer.onDidConflict((event) => events.push(event))

        buffer.setText('Buffer contents')
        buffer.save()

        // Modify the file after the save has been asynchronously initiated
        buffer.onDidSave(() => buffer.append('!'))

        const subscription = buffer.file.onDidChange(() => setTimeout(() => {
          subscription.dispose()
          expect(events.length).toBe(0)
          done()
        }, buffer.fileChangeDelay))
      })

      it('passes setPath to the custom File object', (done) => {
        const newPath = path.join(tempDir, 'temp2.txt')
        fs.writeFileSync(newPath, '')
        buffer.setPath(newPath)
        buffer.setText('test')
        buffer.save().then(() => {
          expect(fs.readFileSync(newPath, 'utf8')).toEqual('TEST')
          done()
        })
      })
    })

    describe('when a permission error occurs', () => {
      if (process.platform !== 'darwin') return

      beforeEach(() => {
        const save = NativeTextBuffer.prototype.save

        spyOn(NativeTextBuffer.prototype, 'save').and.callFake(function (destination, encoding) {
          if (destination === filePath) {
            return Promise.reject({code: 'EACCES', message: 'Permission denied'})
          }

          return save.call(this, destination, encoding)
        })
      })

      it('requests escalated privileges to save the file', (done) => {
        spyOn(fsAdmin, 'createWriteStream').and.callFake(() => fs.createWriteStream(filePath))

        buffer.setText('Buffer contents\n'.repeat(100))

        buffer.save().then(() => {
          expect(fs.readFileSync(filePath, 'utf8')).toEqual(buffer.getText())
          expect(fsAdmin.createWriteStream).toHaveBeenCalled()
          expect(buffer.outstandingSaveCount).toBe(0)
          done()
        })
      })

      it('rejects if writing to the file fails', (done) => {
        const stream = new Writable({
          write (chunk, encoding, callback) {
            process.nextTick(() => callback(new Error('Could not write to stream')))
          }
        })

        spyOn(fsAdmin, 'createWriteStream').and.callFake(() => stream)

        buffer.setText('Buffer contents\n'.repeat(100))
        buffer.save().catch((error) => {
          expect(error.code).toBe('EACCES')
          expect(error.message).toBe('Permission denied')
          expect(buffer.isModified()).toBe(true)
          expect(buffer.outstandingSaveCount).toBe(0)
          done()
        })
      })
    })
  })

  describe('.saveAs', () => {
    let filePath

    beforeEach((done) => {
      filePath = temp.openSync('atom').path
      fs.writeFileSync(filePath, 'a')
      TextBuffer.load(filePath).then((result) => {
        buffer = result
        done()
      })
    })

    it('saves the contents of the buffer to the new path', (done) => {
      const didChangePathHandler = jasmine.createSpy('didChangePathHandler')
      buffer.onDidChangePath(didChangePathHandler)

      const newPath = temp.openSync('atom').path
      buffer.setText('b')
      buffer.saveAs(newPath).then(() => {
        expect(fs.readFileSync(newPath, 'utf8')).toEqual('b')
        expect(didChangePathHandler).toHaveBeenCalledWith(newPath)
        done()
      })
    })

    it('can save to a file in a non-existent directory', (done) => {
      const directory = temp.mkdirSync('atom')
      const newFilePath = path.join(directory, 'a', 'b', 'c', 'new-file')

      buffer.saveAs(newFilePath).then(() => {
        expect(fs.readFileSync(newFilePath, 'utf8')).toBe(buffer.getText())
        expect(buffer.getPath()).toBe(newFilePath)
        done()
      })
    })

    it('stops listening for changes to the old path and starts listening for changes to the new path', (done) => {
      const didChangeHandler = jasmine.createSpy('didChangeHandler')
      buffer.onDidChange(didChangeHandler)

      const newPath = temp.openSync('atom').path
      buffer.saveAs(newPath)
        .then(() => {
          expect(didChangeHandler).not.toHaveBeenCalled()
          fs.writeFileSync(filePath, 'does not trigger a buffer change')
          return timeoutPromise(100)
        })
        .then(() => {
          expect(didChangeHandler).not.toHaveBeenCalled()
          expect(buffer.getText()).toBe('a')
        })
        .then(() => {
          fs.writeFileSync(newPath, 'does trigger a buffer change')
          return timeoutPromise(400)
        })
        .then(() => {
          expect(didChangeHandler).toHaveBeenCalled()
          expect(buffer.getText()).toBe('does trigger a buffer change')
          done()
        })
    })
  })

  describe('.isModified', () => {
    beforeEach((done) => {
      const filePath = temp.openSync('atom').path
      fs.writeFileSync(filePath, '')
      TextBuffer.load(filePath).then((result) => {
        buffer = result
        done()
      })
    })

    describe('when the buffer is changed', () => {
      it('reports the modified status changing to true or false', (done) => {
        const modifiedStatusChanges = []
        buffer.onDidChangeModified((status) => modifiedStatusChanges.push(status))
        expect(buffer.isModified()).toBeFalsy()

        buffer.insert([0, 0], 'hi')
        expect(buffer.isModified()).toBe(true)

        stopChangingPromise()
          .then(() => {
            expect(modifiedStatusChanges).toEqual([true])

            buffer.insert([0, 2], 'ho')
            expect(buffer.isModified()).toBe(true)
            return stopChangingPromise()
          })
          .then(() => {
            expect(modifiedStatusChanges).toEqual([true])

            buffer.undo()
            buffer.undo()
            expect(buffer.isModified()).toBe(false)
            return stopChangingPromise()
          })
          .then(() => {
            expect(modifiedStatusChanges).toEqual([true, false])
            done()
          })
      })
    })

    describe('when the buffer is saved', () => {
      it('reports the modified status changing to false', (done) => {
        buffer.insert([0, 0], 'hi')
        expect(buffer.isModified()).toBe(true)

        const modifiedStatusChanges = []
        buffer.onDidChangeModified((status) => modifiedStatusChanges.push(status))

        buffer.save().then(() => {
          expect(buffer.isModified()).toBe(false)
          stopChangingPromise().then(() => {
            expect(modifiedStatusChanges).toEqual([false])
            done()
          })
        })
      })
    })

    describe('when the buffer is reloaded', () => {
      it('reports the modified status changing to false', (done) => {
        const modifiedStatusChanges = []
        buffer.onDidChangeModified((status) => modifiedStatusChanges.push(status))

        buffer.insert([0, 0], 'hi')

        const subscription = buffer.onDidChangeModified(() => {
          expect(buffer.isModified()).toBe(true)
          expect(modifiedStatusChanges).toEqual([true])
          subscription.dispose()

          buffer.reload().then(() => {
            expect(buffer.isModified()).toBe(false)
            expect(modifiedStatusChanges).toEqual([true, false])
            done()
          })
        })
      })
    })

    it('returns false for an empty buffer with no path', () => {
      buffer2 = new TextBuffer()
      expect(buffer2.isModified()).toBeFalsy()
      buffer2.append('hello')
      expect(buffer2.isModified()).toBeTruthy()
    })

    it('returns true for an empty buffer with a path', (done) => {
      const filePath = path.join(temp.mkdirSync(), 'file-to-delete')
      TextBuffer.load(filePath).then((buffer) => {
        expect(buffer.isModified()).toBe(true)
        done()
      })
    })

    it('returns true for a non-empty buffer with no path', () => {
      buffer2 = new TextBuffer({text: 'something'})
      expect(buffer2.isModified()).toBeTruthy()

      buffer2.append('a')
      expect(buffer2.isModified()).toBeTruthy()

      buffer2.setText('')
      expect(buffer2.isModified()).toBeFalsy()
    })
  })

  describe('.serialize and .deserialize', () => {
    describe('when the disk contents have not changed since serialization', () => {
      it('restores the previous unsaved state of the buffer, along with its markers and history', (done) => {
        const filePath = temp.openSync('atom').path
        fs.writeFileSync(filePath, 'abc\ndef\n')

        TextBuffer.load(filePath).then((result) => {
          buffer = result
          buffer.append('ghi\n')
          const markerLayer = buffer.addMarkerLayer({persistent: true})
          const marker = markerLayer.markRange(Range(Point(1, 2), Point(2, 1)))

          TextBuffer.deserialize(buffer.serialize()).then((buf2) => {
            buffer2 = buf2
            const markerLayer2 = buffer2.getMarkerLayer(markerLayer.id)
            const marker2 = markerLayer2.getMarker(marker.id)
            expect(buffer2.getText()).toBe('abc\ndef\nghi\n')
            expect(marker2.getRange()).toEqual(Range(Point(1, 2), Point(2, 1)))
            expect(buffer2.undo()).toBe(true)
            expect(buffer2.getText()).toBe('abc\ndef\n')

            expect(buffer2.markPosition(Point(0, 0)).id).toBe(buffer.markPosition(Point(0, 0)).id)
            expect(buffer2.addMarkerLayer().id).toBe(buffer.addMarkerLayer().id)
            done()
          })
        })
      })

      it('can restore from a state created with an old version of TextBuffer', (done) => {
        const filePath = temp.openSync('atom').path
        fs.writeFileSync(filePath, 'abc\ndef\n')

        TextBuffer.load(filePath).then((buf) => {
          buffer = buf
          buffer.append('ghi\n')
          const state = buffer.serialize()

          // This was the old serialization format
          delete state.outstandingChanges
          state.text = buffer.getText()

          TextBuffer.deserialize(state).then((buf2) => {
            buffer2 = buf2
            expect(buffer2.getText()).toBe(buffer.getText())
            expect(buffer2.isModified()).toBe(true)
            done()
          })
        })
      })
    })

    describe('when the disk contents have changed since serialization', () => {
      it('loads the disk contents instead of the previous unsaved state', (done) => {
        const filePath = temp.openSync('atom').path
        fs.writeFileSync(filePath, 'abc\ndef\n')
        TextBuffer.load(filePath).then((buf) => {
          buffer = buf
          buffer.append('ghi\n')

          fs.writeFileSync(filePath, 'DISK CHANGE')

          TextBuffer.deserialize(buffer.serialize()).then((buf2) => {
            buffer2 = buf2
            expect(buffer2.getPath()).toBe(buffer.getPath())
            expect(buffer2.getText()).toBe('DISK CHANGE')
            expect(buffer2.isModified()).toBe(false)
            expect(buffer2.undo()).toBe(false)
            expect(buffer2.getText()).toBe('DISK CHANGE')
            done()
          })
        })
      })
    })

    it('serializes the encoding', (done) => {
      const filePath = path.join(__dirname, 'fixtures', 'win1251.txt')
      TextBuffer.load(filePath, {encoding: 'WINDOWS-1251'}).then((buf) => {
        buffer = buf
        TextBuffer.deserialize(buffer.serialize()).then((buf2) => {
          buffer2 = buf2
          expect(buffer2.getEncoding()).toBe('WINDOWS-1251')
          expect(buffer2.getText()).toBe('тест 1234 абвгдеёжз')
          done()
        })
      })
    })
  })

  describe('encoding support', () => {
    it('allows the encoding to be set on creation', (done) => {
      const filePath = path.join(__dirname, 'fixtures', 'win1251.txt')
      TextBuffer.load(filePath, {encoding: 'WINDOWS-1251'}).then((buf) => {
        buffer = buf
        expect(buffer.getEncoding()).toBe('WINDOWS-1251')
        expect(buffer.getText()).toBe('тест 1234 абвгдеёжз')
        done()
      })
    })

    describe('when the buffer is modified', () => {
      describe('when the encoding of the buffer is changed', () => {
        beforeEach((done) => {
          const filePath = path.join(__dirname, 'fixtures', 'win1251.txt')
          TextBuffer.load(filePath).then((result) => {
            buffer = result
            done()
          })
        })

        it('does not reload the contents from the disk', (done) => {
          buffer.setText('ch ch changes')
          buffer.setEncoding('win1251')
          setTimeout(() => {
            expect(buffer.getText()).toBe('ch ch changes')
            done()
          }, 250)
        })
      })
    })

    describe('when the buffer is unmodified', () => {
      describe('when the encoding of the buffer is changed', () => {
        beforeEach((done) => {
          const filePath = path.join(__dirname, 'fixtures', 'win1251.txt')
          TextBuffer.load(filePath).then((result) => {
            buffer = result
            done()
          })
        })

        beforeEach((done) => {
          expect(buffer.getEncoding()).toBe('utf8')
          expect(buffer.getText()).not.toBe('тест 1234 абвгдеёжз')

          buffer.setEncoding('WINDOWS-1251')
          expect(buffer.getEncoding()).toBe('WINDOWS-1251')
          buffer.onDidChange(done)
        })

        it('reloads the contents from the disk', () => {
          expect(buffer.getText()).toBe('тест 1234 абвгдеёжз')
        })
      })
    })

    it('emits an event when the encoding changes', (done) => {
      const filePath = path.join(__dirname, 'fixtures', 'win1251.txt')
      const encodingChanges = []

      TextBuffer.load(filePath).then((result) => {
        buffer = result
        buffer.onDidChangeEncoding((encoding) => encodingChanges.push(encoding))
        buffer.setEncoding('WINDOWS-1251')
        expect(encodingChanges).toEqual(['WINDOWS-1251'])

        buffer.setEncoding('WINDOWS-1251')
        expect(encodingChanges).toEqual(['WINDOWS-1251'])

        buffer2 = new TextBuffer()
        buffer2.onDidChangeEncoding((encoding) => encodingChanges.push(encoding))
        buffer2.setEncoding('WINDOWS-1251')
        expect(encodingChanges).toEqual(['WINDOWS-1251', 'WINDOWS-1251'])

        buffer2.setEncoding('WINDOWS-1251')
        expect(encodingChanges).toEqual(['WINDOWS-1251', 'WINDOWS-1251'])

        done()
      })
    })

    describe('when a buffer\'s encoding is changed', () => {
      beforeEach((done) => {
        const filePath = path.join(__dirname, 'fixtures', 'win1251.txt')
        TextBuffer.load(filePath).then((result) => {
          buffer = result
          buffer.onDidChange(done)
          buffer.setEncoding('WINDOWS-1251')
        })
      })

      it('does not push the encoding change onto the undo stack', () => {
        buffer.undo()
        expect(buffer.getText()).toBe('тест 1234 абвгдеёжз')
      })
    })
  })

  describe('when the file changes on disk', () => {
    let filePath

    beforeEach((done) => {
      filePath = temp.openSync('atom').path
      fs.writeFileSync(filePath, 'abcde')
      TextBuffer.load(filePath).then((result) => {
        buffer = result
        done()
      })
    })

    it('emits a conflict event if the buffer is modified', (done) => {
      buffer.append('f')
      expect(buffer.getText()).toBe('abcdef')
      expect(buffer.isModified()).toBe(true)

      fs.writeFileSync(buffer.getPath(), '  abc')

      const subscription = buffer.onDidConflict(() => {
        subscription.dispose()
        expect(buffer.getText()).toBe('abcdef')
        expect(buffer.isModified()).toBe(true)
        expect(buffer.isInConflict()).toBe(true)
        done()
      })
    })

    it('emits a conflict event if the buffer is modified and backed by a custom file', (done) => {
      const file = new ReverseCaseFile(filePath)
      buffer.setFile(file)

      buffer.append('f')
      expect(buffer.getText()).toBe('abcdef')
      expect(buffer.isModified()).toBe(true)

      fs.writeFileSync(buffer.getPath(), '  abc')

      const subscription = buffer.onDidConflict(() => {
        subscription.dispose()
        expect(buffer.getText()).toBe('abcdef')
        expect(buffer.isModified()).toBe(true)
        expect(buffer.isInConflict()).toBe(true)
        done()
      })
    })

    it('updates the buffer and its markers and notifies change observers if the buffer is unmodified', (done) => {
      expect(buffer.getText()).toEqual('abcde')

      const newTextSuffix = '!'.repeat(1024)
      const newText = ' abc' + newTextSuffix

      const events = []
      buffer.onWillReload((event) => events.push(['will-reload']))
      buffer.onWillChange(() => {
        expect(buffer.getText()).toEqual('abcde')
        events.push(['will-change'])
      })
      buffer.onDidChange((event) => events.push(['did-change', event]))
      buffer.onDidReload((event) => events.push(['did-reload']))

      const markerB = buffer.markRange(Range(Point(0, 1), Point(0, 2)))
      const markerD = buffer.markRange(Range(Point(0, 3), Point(0, 4)))

      fs.writeFileSync(buffer.getPath(), newText)

      const subscription = buffer.onDidReload(() => {
        subscription.dispose()

        expect(buffer.isModified()).toBe(false)
        expect(buffer.getText()).toBe(newText)

        expect(markerB.getRange()).toEqual(Range(Point(0, 2), Point(0, 3)))
        expect(markerD.getRange()).toEqual(Range(Point(0, 4), Point(0, newText.length)))
        expect(markerB.isValid()).toBe(true)
        expect(markerD.isValid()).toBe(false)

        expect(toPlainObject(events)).toEqual(toPlainObject([
          [
            'will-reload'
          ],
          [
            'will-change'
          ],
          [
            'did-change', {
              oldRange: Range(Point(0, 0), Point(0, 5)),
              newRange: Range(Point(0, 0), Point(0, newText.length)),
              changes: [
                {
                  oldRange: Range(Point.ZERO, Point.ZERO),
                  newRange: Range(Point.ZERO, Point(0, 1)),
                  oldText: '',
                  newText: ' '
                },
                {
                  oldRange: Range(Point(0, 3), Point(0, 5)),
                  newRange: Range(Point(0, 4), Point(0, newText.length)),
                  oldText: 'de',
                  newText: newTextSuffix
                }
              ]
            }
          ],
          [
            'did-reload'
          ]
        ]))

        done()
      })
    })

    it('passes the smallest possible change event to onDidChange listeners', (done) => {
      fs.writeFileSync(buffer.getPath(), 'abc de ')

      const events = []
      buffer.onWillChange(() => events.push(['will-change']))
      buffer.onDidChange((event) => events.push(['did-change', event]))

      const subscription = buffer.onDidReload(() => {
        subscription.dispose()

        expect(buffer.getText()).toBe('abc de ')

        expect(toPlainObject(events)).toEqual(toPlainObject([
          [
            'will-change'
          ],
          [
            'did-change', {
              oldRange: Range(Point(0, 3), Point(0, 5)),
              newRange: Range(Point(0, 3), Point(0, 7)),
              changes: [
                {
                  oldRange: Range(Point(0, 3), Point(0, 3)),
                  newRange: Range(Point(0, 3), Point(0, 4)),
                  oldText: '',
                  newText: ' '
                },
                {
                  oldRange: Range(Point(0, 5), Point(0, 5)),
                  newRange: Range(Point(0, 6), Point(0, 7)),
                  oldText: '',
                  newText: ' '
                }
              ]
            }
          ]
        ]))

        done()
      })
    })

    it('does nothing when the file is rewritten with the same contents', (done) => {
      const events = []
      buffer.onWillReload((event) => events.push(event))
      buffer.onDidReload((event) => events.push(event))
      buffer.onDidChange((event) => events.push(event))
      buffer.onDidConflict((event) => events.push(event))

      fs.writeFileSync(buffer.getPath(), 'abcde')

      const subscription = buffer.file.onDidChange(() => {
        subscription.dispose()
        setTimeout(() => {
          expect(buffer.getText()).toBe('abcde')
          expect(events.length).toBe(0)
          done()
        }, buffer.fileChangeDelay + 100)
      })
    })

    it('does not fire duplicate change events when multiple changes happen on disk', (done) => {
      const changeEvents = []
      buffer.onWillChange(() => changeEvents.push('will-change'))
      buffer.onDidChange((event) => changeEvents.push('did-change'))

      // We debounce file system change events to avoid redundant loads. But
      // for large files, another file system change event may occur *after* the
      // debounce interval but *before* the previous load has completed. In
      // that scenario, we still want to avoid emitting redundant change events.
      //
      // This test simulates the buffer taking a long time to load and diff by
      // first reading the file's current contents (copying them to a temp file),
      // then waiting for a period of time longer than the debounce interval,
      // and then performing the actual load.
      const originalLoad = buffer.buffer.load
      spyOn(NativeTextBuffer.prototype, 'load').and.callFake(function (pathToLoad, ...args) {
        const pathToLoadCopy = temp.openSync('atom').path
        fs.writeFileSync(pathToLoadCopy, fs.readFileSync(pathToLoad))
        return timeoutPromise(buffer.fileChangeDelay + 100)
          .then(() => originalLoad.call(this, pathToLoadCopy, ...args))
      })

      fs.writeFileSync(filePath, 'a')
      fs.writeFileSync(filePath, 'ab')
      setTimeout(() => {
        fs.writeFileSync(filePath, 'abc')
        fs.writeFileSync(filePath, 'abcd')
        setTimeout(() => {
          fs.writeFileSync(filePath, 'abcde')
          fs.writeFileSync(filePath, 'abcdef')
        }, buffer.fileChangeDelay + 50)
      }, buffer.fileChangeDelay + 50)

      const subscription = buffer.onDidChange(() => {
        if (buffer.getText() === 'abcdef') {
          expect(changeEvents).toEqual(['will-change', 'did-change'])
          subscription.dispose()
          done()
        }
      })
    })
  })

  describe('when the file is deleted', () => {
    let filePath, closeDeletedFileTabs

    beforeEach((done) => {
      filePath = path.join(temp.mkdirSync(), 'file-to-delete')
      fs.writeFileSync(filePath, 'delete me')
      TextBuffer.load(filePath, {shouldDestroyOnFileDelete: () => closeDeletedFileTabs}).then((result) => {
        buffer = result
        filePath = buffer.getPath() // symlinks may have been converted
        done()
      })
    })

    describe('when the file is modified', () => {
      beforeEach((done) => {
        buffer.setText('I WAS MODIFIED')
        expect(buffer.isModified()).toBeTruthy()
        buffer.file.onDidDelete(() => done())
        fs.removeSync(filePath)
      })

      it('retains its path and reports the buffer as modified', () => {
        expect(buffer.getPath()).toBe(filePath)
        expect(buffer.isModified()).toBeTruthy()
      })
    })

    describe('when the file is not modified', () => {
      beforeEach(() => {
        expect(buffer.isModified()).toBeFalsy()
      })

      describe('when shouldDestroyOnFileDelete returns true', () => {
        beforeEach(() => {
          closeDeletedFileTabs = true
        })

        it('destroys the buffer', (done) => {
          buffer.onDidDestroy(() => done())
          expect(buffer.isDestroyed()).toBeFalsy()
          expect(buffer.isModified()).toBeFalsy()
          fs.removeSync(filePath)
        })
      })

      describe('when shouldDestroyOnFileDelete returns false', () => {
        beforeEach(() => {
          closeDeletedFileTabs = false
        })

        it('retains its path and reports the buffer as modified', (done) => {
          fs.removeSync(filePath)
          buffer.file.onDidDelete(() => {
            expect(buffer.getPath()).toBe(filePath)
            expect(buffer.isModified()).toBeTruthy()
            done()
          })
        })
      })
    })

    describe('when the file is deleted', () => {
      it('notifies all onDidDelete listeners ', (done) => {
        buffer.onDidDelete(() => done())
        fs.removeSync(filePath)
      })
    })

    it('resumes watching of the file when it is re-saved', (done) => {
      buffer.save().then(() => {
        expect(fs.existsSync(buffer.getPath())).toBeTruthy()
        expect(buffer.isInConflict()).toBeFalsy()

        fs.writeFileSync(filePath, 'moo')
        buffer.onDidChange(() => {
          expect(buffer.getText()).toBe('moo')
          done()
        })
      })
    })
  })
})

class ReverseCaseFile {
  constructor (path) {
    this.path = path
  }

  existsSync () {
    return fs.existsSync(this.path)
  }

  getPath () {
    return this.path
  }

  setPath (path) {
    this.path = path
  }

  createReadStream () {
    return fs.createReadStream(this.path).pipe(new Transform({
      transform (chunk, encoding, callback) {
        callback(null, reverseCase(chunk))
      }
    }))
  }

  createWriteStream () {
    const stream = fs.createWriteStream(this.path)
    return new Writable({
      write (chunk, encoding, callback) {
        stream.write(reverseCase(chunk), encoding, callback)
      }
    })
  }

  onDidChange (callback) {
    const watcher = fs.watch(this.path, callback)
    return new Disposable(() => watcher.close())
  }
}

function reverseCase (buffer, encoding) {
  const result = new Buffer(buffer.length)
  for (let i = 0, n = buffer.length; i < n; i++) {
    const character = String.fromCharCode(buffer[i])
    result[i] = (character === character.toLowerCase()
      ? character.toUpperCase()
      : character.toLowerCase()).charCodeAt(0)
  }
  return result
}

function stopChangingPromise () {
  return timeoutPromise(TextBuffer.prototype.stoppedChangingDelay * 2)
}

function timeoutPromise (duration) {
  return new Promise((resolve) => setTimeout(resolve, duration))
}

function toPlainObject (value) {
  return JSON.parse(JSON.stringify(value))
}
