local themeFramework = {}

local tailwind = require("@packages/tailwind")
local fusion = require("@packages/fusion")
local Computed = fusion.Computed
local Value = fusion.Value

local fusionUtils = require("@packages/fusionUtils")
local use = fusionUtils.use

local function traverseObject(obj: any, path: { string })
	for _, part in path do
		if not obj[part] then
			obj[part] = {}
		end

		obj = obj[part]
	end

	return obj
end

local function iterateDeep(obj: any, callback: (path: { string }, value: any) -> ())
	local function iterate(path: { string }, subObj: any)
		for index, value in subObj do
			if typeof(value) == "table" then
				local cloned = table.clone(path)
				table.insert(cloned, index)
				iterate(cloned, value)
			else
				local cloned = table.clone(path)
				table.insert(cloned, index)
				callback(cloned, value)
			end
		end
	end

	iterate({}, obj)
end

local function getDepth(tbl: { [any]: any }, depth: number): number?
	for idx, value in tbl do
		if typeof(value) == "Color3" and idx ~= "color" then
			return depth + 1
		end

		if type(value) == "table" then
			return getDepth(value, depth + 1)
		end

		return depth
	end

	return
end

local function merge(source: { [any]: any }, override: { [any]: any })
	local merged = table.clone(source)

	for key, value in override do
		if key == "_global" then
			for idx, v in merged do
				merged[idx] = merge(v, value)
			end
		end

		if typeof(value) == "table" and value.get then
			value = value:get()
		end

		if typeof(value) == "table" then
			merged[key] = merge(source[key] or {}, value)
			continue
		end

		if typeof(value) == "Color3" and key ~= "color" then
			merged[key] = merge(source[key] or {}, { color = value, transparency = 0 })
			continue
		end

		merged[key] = value
	end

	return merged
end

local function defineComponentColorFunction(
	callback: (themeName: string, primaryColor: tailwind.color) -> componentColorList
): componentColorFunction
	return function(themeName: string)
		return function(primaryColor: string): componentColorList?
			local primary = tailwind[primaryColor]

			if primary == nil then
				warn(`Could not find primary color {primaryColor}`)
				return nil
			end

			local stateTable: componentColorList = callback(themeName, primary)

			if stateTable == nil then
				return nil
			end

			-- mutate all colors into the format we want ({color = color, transparency = 0 or any other number})
			for state, colors in stateTable do
				for colorName, color in colors do
					if typeof(color) == "Color3" then
						stateTable[state][colorName] = { color = color, transparency = 0 }
					else
						if color.transparency == nil then
							color.transparency = 0
						end

						if color.color == nil then
							color.color = Color3.fromRGB(255, 255, 255)
						end

						stateTable[state][colorName] = color
					end
				end
			end

			return stateTable
		end
	end
end

local function computeColorFunctions(
	location: Instance,
	storage: { [string]: { [string]: { [string]: componentColorFunction } } }
)
	for _, component in location:GetChildren() do
		local themeTree: {
			[string]: {
				[string]: componentColorFunction,
			},
		} = {}

		for _, color in component:GetChildren() do
			local variants = {}

			for _, variant in color:GetChildren() do
				variants[variant.Name] = defineComponentColorFunction(require(variant) :: any)
			end

			themeTree[color.Name] = variants
		end

		storage[component.Name] = themeTree
	end
end

function themeFramework.new(componentLocation: Instance, onBuild: ((self: themeFramework) -> ())?): themeFramework
	local self = {
		componentLocation = componentLocation,
		alternativeComponentLocations = Value({}),
		componentFunctions = {},
		theme = {},
		onBuild = onBuild,
		fallback = nil,
	}

	computeColorFunctions(componentLocation, self.componentFunctions)
	return setmetatable(self, { __index = themeFramework }) :: themeFramework
end

function themeFramework.addLocation(self: themeFramework, componentLocation: Instance)
	local newComponentFunctions = {}
	computeColorFunctions(componentLocation, newComponentFunctions)

	local oldLocations = self.alternativeComponentLocations:get()
	table.insert(oldLocations, newComponentFunctions)
	self.alternativeComponentLocations:set(oldLocations)
end

function themeFramework.get(
	self: themeFramework,
	component: string,
	colorName: fusion.CanBeState<string>,
	variant: fusion.CanBeState<string>,
	state: fusion.CanBeState<string>,
	override: fusion.CanBeState<optionalColorTable>?
): useColorFunction
	local overrideDepth = override and Computed(function()
		return getDepth(use(override), 0)
	end) or -1

	local colorComputed = Computed(function()
		local baseColor: colorBase

		for _, location in self.alternativeComponentLocations:get() do
			baseColor = location[component]

			if baseColor then
				break
			end
		end

		if not baseColor then
			baseColor = self.theme[component]
		end

		local usedColorName = use(colorName)
		local usedVariant = use(variant)
		local usedState = use(state)

		if baseColor == nil then
			warn(`Could not get base color for component {component}: {usedColorName} -> {usedVariant}.{usedState}`)
			return nil
		end

		local indexColor = usedColorName

		if baseColor[indexColor] == nil then
			indexColor = "default"
		end

		if baseColor[indexColor] == nil or baseColor[indexColor][usedVariant] == nil then
			warn(`Could not get color for component {component}: {usedColorName} -> {usedVariant}.{usedState}`)
			return nil
		end

		local colorFunction = baseColor[indexColor][usedVariant]

		if colorFunction == nil then
			warn(`Could not get color for component {component}: {usedColorName} -> {usedVariant}.{usedState}`)
			return nil
		end

		local success, colorData = pcall(use(colorFunction), usedColorName)

		if not success or colorData == nil or colorData[usedState] == nil then
			warn(
				`Could not get state within color (or the primary color) for component {component}: {usedColorName} -> {usedVariant}.{usedState}`
			)
			return nil
		end

		if use(overrideDepth) == 2 then
			colorData = merge(colorData, use(override))
		end

		local stateData = colorData[usedState]

		if use(overrideDepth) == 1 then
			stateData = merge(stateData, use(override))
		end

		return stateData
	end)

	return function(index, reactive)
		if reactive then
			return Computed(function()
				local fallbackColor = {
					color = self.fallback and self.fallback:get() or Color3.fromRGB(255, 255, 255),
					transparency = 1,
				}

				local colorData = colorComputed:get()

				if colorData == nil then
					return fallbackColor
				end

				local color = colorData[use(index)]

				if color == nil then
					return fallbackColor
				end

				if use(overrideDepth) == 0 then
					local overrideTable = use(override) :: color
					local originalColor = {
						transparency = use(color.transparency),
						color = use(color.color),
						shadow = use(color.shadow),
					}

					return merge(originalColor, overrideTable)
				end

				return {
					color = use(color.color),
					transparency = use(color.transparency),
					shadow = use(color.shadow),
				}
			end)
		end

		-- we move this dependency here instead of at the top so that no unneeded dependencies are registered resulting in unneeded rerenders
		local fallbackColor = {
			color = self.fallback and self.fallback:get() or Color3.fromRGB(255, 255, 255),
			transparency = 1,
		}

		local colorData = colorComputed:get()

		if colorData == nil then
			return fallbackColor
		end

		local color = colorData[use(index)]

		if color == nil then
			return fallbackColor
		end

		if use(overrideDepth) == 0 then
			local overrideTable = use(override) :: color
			local originalColor = {
				transparency = use(color.transparency),
				color = use(color.color),
				shadow = use(color.shadow),
			}

			return merge(originalColor, overrideTable)
		end

		return {
			color = use(color.color),
			transparency = use(color.transparency),
			shadow = use(color.shadow),
		}
	end
end

function themeFramework.build(self: themeFramework, theme: string): componentColorList
	local builtTheme = {}

	for componentName, componentColors in self.componentFunctions do
		for colorName, color in componentColors do
			for variantName, variant in color do
				if builtTheme[componentName] == nil then
					builtTheme[componentName] = {}
				end

				if builtTheme[componentName][colorName] == nil then
					builtTheme[componentName][colorName] = {}
				end

				builtTheme[componentName][colorName][variantName] = variant(theme)
			end
		end
	end

	if self.onBuild then
		self:onBuild(theme)
	end

	return builtTheme
end

function themeFramework.load(self: themeFramework, builtTheme: componentColorList)
	iterateDeep(builtTheme, function(path, value)
		if typeof(value) ~= "table" then
			local lastPath = path[#path]
			table.remove(path, #path)

			local traversed = traverseObject(self.theme, path)

			if traversed[lastPath] == nil then
				traversed[lastPath] = Value(value)
			elseif traversed[lastPath]:get() ~= value then
				traversed[lastPath]:set(value)
			end
		end
	end)
end

function themeFramework.setFallback(self: themeFramework, fallback: Color3)
	if self.fallback then
		self.fallback:set(fallback)
	else
		self.fallback = Value(fallback)
	end
end

type componentColorFunction = (themeName: string) -> getColorFunction
type colorBase = { [string]: { [string]: getColorFunction } }

export type getColorFunction = (primaryColor: string) -> componentColorList
export type useColorFunction =
	((index: fusion.CanBeState<string>, reactive: true) -> fusion.Computed<color>)
	& ((index: fusion.CanBeState<string>, reactive: false?) -> color)

export type componentColorList = {
	[string]: {
		[string]: color,
	},
}

export type color = {
	color: Color3,
	transparency: number,
	shadow: number?,
}

export type colorOptional = {
	color: Color3?,
	transparency: number?,
	shadow: number?,
}

export type colorTable = color | {
	[string]: colorTable,
}

export type optionalColorTable = colorOptional | {
	[string]: optionalColorTable,
}

export type themeFramework = typeof(setmetatable(
	{} :: {
		componentLocation: Instance,
		alternativeComponentLocations: fusion.Value<{ { [string]: { [string]: { [string]: getColorFunction } } } }>,
		componentFunctions: {
			[string]: {
				[string]: {
					[string]: componentColorFunction,
				},
			},
		},
		theme: { [string]: { [string]: { [string]: getColorFunction } } },
		onBuild: (self: themeFramework, themeName: string) -> (),
		fallback: fusion.Value<Color3>?,
	},
	{ __index = themeFramework }
))

return themeFramework
