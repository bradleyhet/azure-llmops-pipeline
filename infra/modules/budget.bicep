// Monthly cost budget for the resource group, in the subscription's billing currency.
// A budget only sends email; it never stops or caps spending. The hard ceilings are elsewhere:
// maxReplicas on the app, ASK_PER_DAY in the app, the workspace daily cap and the OpenRouter
// key's credit limit.
param name string
param amount int
param contactEmails array

// Azure refuses any change to an existing budget's start date ("Start date of budgets cannot be
// updated"), so the date is fixed per environment in its parameter file and never derived from
// the clock. Restating "the first of this month" broke the first deploy after the month rolled over.
@description('First day of the month the budget was created in, yyyy-MM-dd.')
param startDate string

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
