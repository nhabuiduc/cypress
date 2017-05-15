require("../spec_helper")

fs = require("fs-extra")
path = require("path")
Promise = require("bluebird")
FileUtil = require("#{root}lib/util/file")
appData = require("#{root}lib/util/app_data")
savedState = require("#{root}lib/saved_state")

fs = Promise.promisifyAll(fs)

describe "lib/saved_state", ->
  beforeEach ->
    fs.unlinkAsync(savedState.path).catch ->
      ## ignore error if file didn't exist in the first place

  it "is an instance of FileUtil", ->
    expect(savedState).to.be.instanceof(FileUtil)

  it "sets file path to app data path and file name to 'state'", ->
    expect(savedState.path).to.equal(path.join(appData.path(), "state.json"))