// Monthly cost budget for the resource group, in the subscription's billing currency.
// A budget only sends email; it never stops or caps spending. The hard ceilings are elsewhere:
// maxReplicas on the app, ASK_PER_DAY in the app, the workspace daily cap and the OpenRouter
// key's credit limit.
param name string
param amount int
param contactEmails array

// A past start date must fall inside the current month, so each deploy restates the first of
// this month. utcNow() is only allowed as a parameter default, hence a parameter.
param startDate string = '${utcNow('yyyy-MM')}-01'

var notify = {
  enabled: true
  operator: 'GreaterThan'
  contactEmails: contactEmails
  locale: 'en-gb'
}

resource budget 'Microsoft.Consumption/budgets@2023-11-01' = {
  name: name
  properties: {
    category: 'Cost'
    amount: amount
    timeGrain: 'Monthly'
    timePeriod: {
      startDate: startDate
    }
    notifications: {
      actual50: union(notify, { threshold: 50, thresholdType: 'Actual' })
      actual80: union(notify, { threshold: 80, thresholdType: 'Actual' })
      actual100: union(notify, { threshold: 100, thresholdType: 'Actual' })
      forecast100: union(notify, { threshold: 100, thresholdType: 'Forecasted' })
    }
  }
}
