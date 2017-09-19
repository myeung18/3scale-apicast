return {
  -- First service
  ["123"] = {
    -- Prod environment
    prod = "http://prod.myfirstservice.corp",

    -- Dev environment
    dev = "http://dev.myfirstservice.corp"
  },

  -- Second service
  ["456"] = {
    -- Prod environment
    prod = "http://prod.myservice.corp",

    -- Dev environment
    dev = "http://dev.myservice.corp",

    -- Default variant (if nothing matches): sandbox environment
    _default = "http://sandbox.myservice.corp"
  }
}
