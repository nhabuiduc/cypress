_ = require("lodash")

$Cy = require("../../cypress/cy")
$Location = require("../../cypress/location")
$Log = require("../../cypress/log")
$Server = require("../../cypress/server")
utils = require("../../cypress/utils")

validHttpMethodsRe = /^(GET|POST|PUT|DELETE|PATCH|HEAD|OPTIONS)$/i
requestXhrRe       = /\.request$/
validAliasApiRe    = /^(\d+|all)$/

server = null

getServer = ->
  server ? unavailableErr.call(@)

abort = ->
  if server
    server.abort()

isUrlLikeArgs = (url, response) ->
  (not _.isObject(url) and not _.isObject(response)) or
    (_.isRegExp(url) or _.isString(url))

getUrl = (options) ->
  options.originalUrl or options.url

unavailableErr = ->
  utils.throwErrByPath("server.unavailable")

getDisplayName = (route) ->
  if route and route.response? then "xhr stub" else "xhr"

stripOrigin = (url) ->
  location = $Location.create(url)
  url.replace(location.origin, "")

setRequest = (xhr, alias) ->
  requests = @state("requests") ? []

  requests.push({
    xhr: xhr
    alias: alias
  })

  @state("requests", requests)

setResponse = (xhr) ->
  obj = _.find @state("requests"), {xhr: xhr}

  responses = @state("responses") ? []

  ## we could be setting response from
  ## multiple places so this should first
  ## see if we find the xhr in responses
  ## and bail if we do.
  responses.push({
    xhr: xhr
    alias: obj?.alias
  })

  @state("responses", responses)

defaults = {
  method: undefined
  status: undefined
  delay: undefined
  headers: undefined ## response headers
  response: undefined
  autoRespond: undefined
  waitOnResponses: undefined
  onAbort: undefined
  onRequest: undefined ## need to rebind these to 'cy' context
  onResponse: undefined
}

$Cy.extend({
  getXhrServer: ->
    @state("server") ? unavailableErr.call(@)

  startXhrServer: (testId) ->
    logs = {}

    cy = @

    @state "server", $Server.create({
      testId: testId
      xhrUrl: @Cypress.config("xhrUrl")
      stripOrigin: stripOrigin

      ## shouldnt these stubs be called routes?
      ## rename everything related to stubs => routes
      onSend: (xhr, stack, route) =>
        alias = route?.alias

        setRequest.call(@, xhr, alias)

        if rl = route and route.log
          numResponses = rl.get("numResponses")
          rl.set "numResponses", numResponses + 1

        logs[xhr.id] = log = $Log.command({
          message:   ""
          name:      "xhr"
          displayName: getDisplayName(route)
          alias:     alias
          aliasType: "route"
          type:      "parent"
          event:     true
          consoleProps: =>
            consoleObj = {
              Alias:         alias
              Method:        xhr.method
              URL:           xhr.url
              "Matched URL": route?.url
              Status:        xhr.statusMessage
              Duration:      xhr.duration
              "Stubbed":     if route and route.response? then "Yes" else "No"
              Request:       xhr.request
              Response:      xhr.response
              XHR:           xhr._getXhr()
            }

            if route and route.is404
              consoleObj.Note = "This request did not match any of your routes. It was automatically sent back '404'. Setting cy.server({force404: false}) will turn off this behavior."

            consoleObj.groups = ->
              [
                {
                  name: "Initiator"
                  items: [stack]
                  label: false
                }
              ]

            consoleObj
          renderProps: ->
            status = switch
              when xhr.aborted
                indicator = "aborted"
                "(aborted)"
              when xhr.status > 0
                xhr.status
              else
                indicator = "pending"
                "---"

            indicator ?= if /^2/.test(status) then "successful" else "bad"

            {
              message: "#{xhr.method} #{status} #{_.truncate(stripOrigin(xhr.url), 20)}"
              indicator: indicator
            }
        })

        log.snapshot("request")

      onLoad: (xhr) =>
        setResponse.call(@, xhr)

        if log = logs[xhr.id]
          log.snapshot("response").end()

      onNetworkError: (xhr) ->
        err = utils.cypressErr(utils.errMessageByPath("xhr.network_error"))

        if log = logs[xhr.id]
          log.snapshot("failed").error(err)

      onFixtureError: (xhr, err) ->
        err = utils.cypressErr(err)

        @onError(xhr, err)

      onError: (xhr, err) =>
        err.onFail = ->

        if log = logs[xhr.id]
          log.snapshot("error").error(err)

        @fail(err)

      onXhrAbort: (xhr, stack) =>
        setResponse.call(@, xhr)

        err = new Error utils.errMessageByPath("xhr.aborted")
        err.name = "AbortError"
        err.stack = stack

        if log = logs[xhr.id]
          log.snapshot("aborted").error(err)

      onAnyAbort: (route, xhr) =>
        if route and _.isFunction(route.onAbort)
          route.onAbort.call(@, xhr)

      onAnyRequest: (route, xhr) =>
        if route and _.isFunction(route.onRequest)
          route.onRequest.call(@, xhr)

      onAnyResponse: (route, xhr) =>
        if route and _.isFunction(route.onResponse)
          route.onResponse.call(@, xhr)
    })

  getPendingRequests: ->
    return [] if not requests = @state("requests")

    return requests if not responses = @state("responses")

    _.difference requests, responses

  getCompletedRequests: ->
    @state("responses") ? []

  _getLastXhrByAlias: (alias, prop) ->
    ## find the last request or response
    ## which hasnt already been used.
    xhrs = @state(prop) ? []

    ## allow us to handle waiting on both
    ## the request or the response part of the xhr
    privateProp = "_has#{prop}BeenWaitedOn"

    for obj in xhrs
      ## we want to return the first xhr which has
      ## not already been waited on, and if its alias matches ours
      if !obj[privateProp] and obj.alias is alias
        obj[privateProp] = true
        return obj.xhr

  ## this should actually be getRequestsByAlias
  ## since this will return all requests and not
  ## responses
  getResponsesByAlias: (alias) ->
    [alias, prop] = alias.split(".")

    if prop and not validAliasApiRe.test(prop)
      utils.throwErrByPath "get.alias_invalid", {
        args: { prop }
      }

    if prop is "0"
      utils.throwErrByPath "get.alias_zero", {
        args: { alias }
      }

    ## return an array of xhrs
    matching = _.chain(@state("responses")).filter({alias: alias}).map("xhr").value()

    ## return the whole array if prop is all
    return matching if prop is "all"

    ## else if prop its a digit and we need to return
    ## the 1-based response from the array
    return matching[_.toNumber(prop) - 1] if prop

    ## else return the last matching response
    return _.last(matching)

  getLastXhrByAlias: (alias) ->
    [str, prop] = alias.split(".")

    if prop
      if prop is "request"
        return @_getLastXhrByAlias(str, "requests")
      else
        if prop isnt "response"
          utils.throwErrByPath "wait.alias_invalid", {
            args: { prop, str }
          }

    @_getLastXhrByAlias(str, "responses")

  getXhrTypeByAlias: (alias) ->
    if requestXhrRe.test(alias) then "request" else "response"
})

module.exports = (Cypress, Commands) ->
  Cypress.on "before:unload", ->
    ## if our page is going away due to
    ## a form submit / anchor click then
    ## we need to cancel all outstanding
    ## XHR's so the command log displays
    ## correctly
    if server
      server.abort()

  Cypress.on "abort", abort

  Cypress.on "test:before:hooks", (test = {}) ->
    abort()

    server = @startXhrServer(test.id)

  Cypress.on "before:window:load", (contentWindow) ->
    if server
      ## dynamically bind the server to whatever is currently running
      $Server.bindTo contentWindow, _.bind(getServer, @)
    else
      unavailableErr.call(@)

  Commands.addAll({
    server: (options) ->
      if arguments.length is 0
        options = {}

      if not _.isObject(options)
        utils.throwErrByPath("server.invalid_argument")

      _.defaults options,
        enable: true ## set enable to false to turn off stubbing

      ## if we disable the server later make sure
      ## we cannot add cy.routes to it
      @state("serverIsStubbed", options.enable)

      @getXhrServer().set(options)

    route: (args...) ->
      ## TODO:
      ## if we return a function which returns a promise
      ## then we should be handling potential timeout issues
      ## just like cy.then does

      ## method / url / response / options
      ## url / response / options
      ## options

      ## by default assume we have a specified
      ## response from the user
      hasResponse = true

      if not @state("serverIsStubbed")
        utils.throwErrByPath("route.failed_prerequisites")

      ## get the default options currently set
      ## on our server
      options = o = @getXhrServer().getOptions()

      ## enable the entire routing definition to be a function
      parseArgs = (args...) =>
        switch
          when _.isObject(args[0]) and not _.isRegExp(args[0])
            ## we dont have a specified response
            if not _.has(args[0], "response")
              hasResponse = false

            options = o = _.extend {}, options, args[0]

          when args.length is 0
            utils.throwErrByPath "route.invalid_arguments"

          when args.length is 1
            o.url = args[0]

            hasResponse = false

          when args.length is 2
            ## if our url actually matches an http method
            ## then we know the user doesn't want to stub this route
            if _.isString(args[0]) and validHttpMethodsRe.test(args[0])
              o.method = args[0]
              o.url    = args[1]

              hasResponse = false
            else
              o.url      = args[0]
              o.response = args[1]

          when args.length is 3
            if validHttpMethodsRe.test(args[0]) or isUrlLikeArgs(args[1], args[2])
              o.method    = args[0]
              o.url       = args[1]
              o.response  = args[2]
            else
              o.url       = args[0]
              o.response  = args[1]

              _.extend o, args[2]

          when args.length is 4
            o.method    = args[0]
            o.url       = args[1]
            o.response  = args[2]

            _.extend o, args[3]

        if _.isString(o.method)
          o.method = o.method.toUpperCase()

        _.defaults options, defaults

        if not options.url
          utils.throwErrByPath "route.url_missing"

        if not (_.isString(options.url) or _.isRegExp(options.url))
          utils.throwErrByPath "route.url_invalid"

        if not validHttpMethodsRe.test(options.method)
          utils.throwErrByPath "route.method_invalid", {
            args: { method: o.method }
          }

        if hasResponse and not options.response?
          utils.throwErrByPath "route.response_invalid"

        ## convert to wildcard regex
        if options.url is "*"
          options.originalUrl = "*"
          options.url = /.*/

        ## look ahead to see if this
        ## command (route) has an alias?
        if alias = @getNextAlias()
          options.alias = alias

        if _.isFunction(o.response)
          getResponse = =>
            o.response.call(@privateState("runnable").ctx, options)

          ## allow route to return a promise
          Promise.try(getResponse)
          .then (resp) ->
            options.response = resp

            route()
        else
          route()

      route = =>
        ## if our response is a string and
        ## a reference to an alias
        if _.isString(o.response) and aliasObj = @getAlias(o.response, "route")
          ## reset the route's response to be the
          ## aliases subject
          options.response = aliasObj.subject

        options.log = $Log.route
          method:   options.method
          url:      getUrl(options)
          status:   options.status
          response: options.response
          alias:    options.alias
          isStubbed: options.response?
          numResponses: 0
          consoleProps: ->
            Method:   options.method
            URL:      getUrl(options)
            Status:   options.status
            Response: options.response
            Alias:    options.alias

        return @getXhrServer().route(options)

      if _.isFunction(args[0])
        getArgs = =>
          args[0].call(@privateState("runnable").ctx)

        Promise.try(getArgs)
        .then(parseArgs)
      else
        parseArgs(args...)
  })