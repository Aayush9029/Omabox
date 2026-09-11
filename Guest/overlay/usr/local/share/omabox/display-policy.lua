local monitor = hl.monitor
local rules = {}
local requested = os.getenv("OMABOX_DISPLAY_SCALE") or "auto"
local requested_scale = tonumber(requested)
if requested_scale == nil or requested_scale ~= requested_scale or requested_scale < 0.25 or requested_scale > 4 then
  requested_scale = nil
end

local function policy(output, description)
  local rule = rules[output]
  if rule == nil then
    for selector, candidate in pairs(rules) do
      if selector:sub(1, 5) == "desc:" and description:sub(1, #selector - 5) == selector:sub(6) then
        rule = candidate
        break
      end
    end
  end
  rule = rule or rules[""] or {}
  if (rule.mode ~= nil and rule.mode ~= "preferred") or rule.disabled == true
      or (rule.transform ~= nil and rule.transform ~= 0)
      or (rule.mirror ~= nil and rule.mirror ~= "") then
    return "manual"
  end
  local scale = rule.scale == nil and requested_scale or tonumber(rule.scale)
  if scale ~= nil and scale == scale and scale >= 0.25 and scale <= 4 then
    return "fixed:" .. tostring(scale)
  end
  return "automatic"
end

function hl.monitor(rule)
  local result = monitor(rule)
  if type(rule) == "table" and type(rule.output) == "string" then
    local previous = rules[rule.output] or {}
    for _, key in ipairs({ "mode", "scale", "disabled", "transform", "mirror" }) do
      if rule[key] ~= nil then previous[key] = rule[key] end
    end
    rules[rule.output] = previous
  end
  return result
end

omabox_display_policy = policy
omabox_apply_display = function(output, description, expected_policy, rule)
  if policy(output, description) == expected_policy and expected_policy ~= "manual" then
    monitor(rule)
  end
end
