--[[
--// RDHook \\--

A Discord webhook module.

Features:
- Fully typed with intellisense and function documentation.
- Automatic format conversion:
	- Converts DateTime and Unix timestamps to ISO-8601.
	- Converts Color3 to Discord's decimal format.
- Supports Secret objects for secure handling of webhook URLs.
- Built-in rate limits, error handling and auto-retrying.
- Supports every current webhook message feature (polls, threads, flags, etc.).

	Licensed under the MIT License:
		https://github.com/Nowoshire/Luau-Float-Precision/blob/main/LICENSE

		MIT License
		
		Copyright (c) 2025-2026 Nowoshire
		
		Permission is hereby granted, free of charge, to any person obtaining a copy
		of this software and associated documentation files (the "Software"), to deal
		in the Software without restriction, including without limitation the rights
		to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
		copies of the Software, and to permit persons to whom the Software is
		furnished to do so, subject to the following conditions:
		
		The above copyright notice and this permission notice shall be included in all
		copies or substantial portions of the Software.
		
		THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
		IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
		FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
		AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
		LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
		OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
		SOFTWARE.
]]

--[[ Constants ]]--
-------------------
-- Configuration
local QUEUE_MAX_SIZE = 10 -- Maximum number of requests allowed in queue, excess requests get dropped
local DEFAULT_BUCKET_LIMIT = 5 -- Ratelimit bucket limit
local SEND_MAX_ATTEMPTS = 3 -- Maximum number of attempts to make to send a message
local ADDITIONAL_RETRY_WAIT = 0.5 -- Additional time to wait before retrying after retry_after returned from API, may help reduce errors

-- Other
local ERRMSGS_HTTP_BAD_REQUEST = {
	"This secret cannot be used for a specified domain",
	"Invalid request options",
	"Empty URL",
	"URL must be http",
	"HttpError: InvalidUrl"
}

--[[ Services ]]--
------------------
local HttpService = game:GetService("HttpService")

--[[ Module ]]--
----------------
local RDHook = {}

--[[ Class Declarations ]]--
----------------------------
local internalgcmeta = {__mode = "ks"} -- weak keys, GC shrinkable

-- Webhook Class --
local webhookClass = {
	internal = setmetatable({} :: {[WebhookObject]: internalWebhookObj}, internalgcmeta),
	schema = {}
}

--[[ Types ]]--
---------------

-- Payload Types --
-- Basic types
export type timestamp = DateTime | number | string
export type bitfield = {("SUPPRESS_EMBEDS"?) & ("SUPPRESS_NOTIFICATIONS"?)} | number

-- Complex types
export type WebhookEmbedField = {
	name: string,
	value: string,
	inline: boolean?
}
export type WebhookEmbed = {
	color: (Color3 | number)?,
	author: {
		name: string,
		url: string?,
		icon_url: string?
	}?,
	title: string?,
	url: string?,
	description: string?,
	fields: {WebhookEmbedField}?,
	thumbnail: {url: string}?,
	image: {url: string}?,
	footer: {
		text: string,
		icon_url: string?
	}?,
	timestamp: timestamp?
}
export type WebhookPollAnswer = {
	poll_media: {
		text: string?,
		emoji: {
			id: number?,
			name: string?
		}?
	}
}
export type WebhookPayload = {
	username: string?,
	avatar_url: string?,
	content: string?,
	embeds: {WebhookEmbed}?,
	poll: {
		question: {text: string},
		answers: {WebhookPollAnswer},
		duration: number?,
		allow_multiselect: boolean?
	}?,
	tts: boolean?,
	allowed_mentions: {
		parse: {string?}?,
		roles: {number?}?,
		users: {number?}?
	}?,
	flags: bitfield?,
	thread_name: string?,
	applied_tags: {number}?
}

-- Other Types --
-- Webhook id and token pair
type WebhookCredentials = Secret | string

-- Webhook object type
type internalWebhookObj = {
	Credentials: WebhookCredentials, IsInvalid: boolean, RequestQueue: {thread}, RateLimitResetTask: thread?,
	IsRateLimited: boolean, RateLimitReset: number, RateLimitRemaining: number
} & {} -- silence cannot add indexer to table warning

-- User-facing webhook object type with restrictions.
export type WebhookObject = {
	read Credentials: WebhookCredentials, read IsInvalid: boolean,
	read IsRateLimited: boolean, read RateLimitReset: number, read RateLimitRemaining: number
} & typeof({SendAsync = webhookClass.schema.SendAsync}) -- force methods to show

-- HTTP RequestAsync Types
type HttpRequestOptions = {
	Url: Secret | string,
	Method: ("GET" | "HEAD" | "POST" | "PUT" | "DELETE" | "OPTIONS" | "TRACE" | "PATCH")?,
	Headers: {[string]: any}?,
	Body: string?,
	Compress: Enum.HttpCompression?
}

type HttpRequestResponse = {
	Success: boolean,
	StatusCode: number,
	StatusMessage: string,
	Headers: {
		["x-ratelimit-limit"]: string,
		["x-ratelimit-remaining"]: string,
		["x-ratelimit-reset"]: string,
		["x-ratelimit-reset-after"]: string,
		[string]: any
	},
	Body: string
}

-- User Thumbnail Types
type thumbnailType = "avatar-headshot" | "avatar-bust" | "avatar"
type thumbnailSize = "48x48" | "50x50" | "60x60" | "75x75" | "100x100" | "110x110" | "150x150" | "180x180" | "352x352" | "420x420" | "720x720"
type thumbnailFormat = "Png" | "Jpeg" | "Webp"

--[[ Private Functions ]]--
---------------------------

--[[
Throws an error if <code>a</code> resolves to <code>false</code> or <code>nil</code>.
]]
local function assertMemberCall(a, level: number?)
	if not a then
		error(`Expected ':' not '.' calling member function {debug.info(level and level-1 or 2, "n")}`, level and level or 3)
	end
	
	return a
end

--[[
Throws an error if typeof of <code>arg</code> does not match <code>expect</code>.
]]
local function assertArgType(arg: any, expect: string, argnum: number?, optional: boolean?, level: number?)
	if arg ~= nil and not optional then
		local argType = typeof(arg)
		if argType ~= expect then
			error(`invalid argument #1 to '{debug.info(level and level-1 or 2, "n")}' ({expect} expected{optional and " when specified" or ""}, got {argType})`, level)
		end
	end
end

--[[
<strong>[YIELDS]</strong>
Sends an HTTP request using any HTTP method given a dictionary of information.

Returns a <code>boolean</code> indicating the request's success, the response dictionary or error message, and a <code>boolean</code> indicating if the request was bad.
]]
local function requestAsync(requestOptions: HttpRequestOptions): (boolean, HttpRequestResponse | string, boolean?)
	local callSuccess, response: HttpRequestResponse | string = pcall(HttpService.RequestAsync, HttpService, requestOptions)
	
	-- Success
	if callSuccess then
		return true, response, false
	end
	
	-- Bad request?
	if table.find(ERRMSGS_HTTP_BAD_REQUEST, response :: string) then
		return false, response, true
	end
	
	-- Timed out or other failure
	return false, response :: string, false
end

local function traceback(level: number?)
	return debug.traceback("-- Traceback --", level or 2)
end

--[[
Resets the ratelimit of the provided internal webhook object, resuming threads in the queue.
]]
local function resetRatelimit(internal: internalWebhookObj)
	internal.RateLimitResetTask = nil
	internal.IsRateLimited = false
	internal.RateLimitRemaining = DEFAULT_BUCKET_LIMIT
	
	local requestQueue = internal.RequestQueue
	
	-- Resume waiting
	for i = 1, DEFAULT_BUCKET_LIMIT do
		local queuedThread = requestQueue[i]
		if not queuedThread then
			break
		end
		
		task.spawn(queuedThread)
		requestQueue[i] = nil
	end
end

-- Conversion functions

local function color3ToDec(color: Color3)
	return tonumber(color:ToHex(), 16) :: number
end

local BITFIELD_FLAGS = {
	SUPPRESS_EMBEDS = 2 ^ 2,
	SUPPRESS_NOTIFICATIONS = 2 ^ 12
}

local function bitfieldToDec(bitfield: bitfield): number
	local bitDec = 0
	local seenFlags = {}
	
	for _, flag in bitfield do
		if seenFlags[flag] then
			continue
		end
		seenFlags[flag] = true
		
		local flagDec: number? = BITFIELD_FLAGS[flag]
		if flagDec then
			bitDec += flagDec
		end
	end
	
	return bitDec
end

--[[ Class Setup ]]--
---------------------

-- Webhook Class --
webhookClass.metatable = {
	__index = function(self: WebhookObject, k: string)
		local internalValue = webhookClass.internal[self][k]
		
		return if internalValue ~= nil then internalValue else webhookClass.schema[k]
	end,
	__tostring = function(self: WebhookObject)
		return "Webhook " .. tostring(self.Credentials)
	end
}

--[[
<strong>[USUALLY YIELDS]</strong>

Sends a given message payload with the webhook.
Returns a <code>boolean</code> describing whether the message sent successfully, the request response (if any), and a <code>string</code> describing the failure reason if it did not succeed.

<strong>NOTE:</strong> May return immediately if the webhook was invalidated (invalid id or token according to Discord API) or request queue is full.
]]
function webhookClass.schema.SendAsync(self: WebhookObject, payload: WebhookPayload): (boolean, (HttpRequestResponse | string)?, string?)
	local internal = assertMemberCall(webhookClass.internal[self])
	assertArgType(payload, "table", 1, true)
	
	-- Webhook is invalid, don't try
	if internal.IsInvalid then
		warn(`Cannot send request with invalid webhook {self}.\n{traceback(3)}`)
		return false, nil, "InvalidWebhook"
	end
	
	-- Drop excessive requests
	if #internal.RequestQueue > QUEUE_MAX_SIZE then
		warn(`Dropped request because send queue was exhausted for {self}, try sending fewer requests.\n{traceback(3)}`)
		return false, nil, "ExhaustedQueue"
	end
	
	-- Conversions
	if payload.embeds then
		-- Embeds
		for _, embed in payload.embeds do
			-- Color conversion
			local color = embed.color
			if color then
				if typeof(color) == "Color3" then
					embed.color = color3ToDec(color)
				end
			end
			
			-- Timestamp conversion
			local timestamp = embed.timestamp
			if timestamp then
				local timestampType = typeof(timestamp)
				if timestampType == "DateTime" then
					embed.timestamp = (timestamp :: DateTime):ToIsoDate()
				elseif timestampType == "number" then
					embed.timestamp = DateTime.fromUnixTimestampMillis(timestamp :: number * 1000):ToIsoDate()
				end
			end
		end
		
		-- Message Flags
		local flags = payload.flags
		if flags and type(flags) == "table" then
			payload.flags = bitfieldToDec(flags)
		end
	end
	
	-- Prepare to send
	local jsonData = HttpService:JSONEncode(payload)
	local credentials = internal.Credentials
	local requestOptions: HttpRequestOptions = {
		Method = "POST",
		Headers = {
			["Content-Type"] = "application/json"
		},
		Body = jsonData,
		Url = credentials
	}
	
	-- Queueing if rate limited
	if internal.IsRateLimited then
		warn(`Added request to queue because {self} is ratelimited, excess requests will be dropped. Try sending fewer requests.\n{traceback(3)}`)
		
		table.insert(internal.RequestQueue, coroutine.running())
		coroutine.yield()
		
		if internal.IsInvalid then
			warn(`Webhook {self} invalidated during queue!`)
			return false, nil, "InvalidWebhook"
		end
	end
	
	-- Pre-emptive rate limiting
	internal.RateLimitRemaining -= 1
	if internal.RateLimitRemaining <= 0 then
		internal.IsRateLimited = true
	end
	
	-- Send message
	local success: boolean, response: HttpRequestResponse | string, apiFailReason: string?
	
	for i = 1, SEND_MAX_ATTEMPTS do
		local badRequest
		success, response, badRequest = requestAsync(requestOptions)
		
		-- Request errored
		if not success then
			-- Was our request bad?
			if badRequest then
				apiFailReason = "BadRequest"
				internal.RateLimitRemaining = math.min(internal.RateLimitRemaining + 1, DEFAULT_BUCKET_LIMIT) -- Request never reached Discord
				break
			end
			
			-- Timed out or something else went wrong
			apiFailReason = "UnexpectedFailure"
			
			local retryAfter = 2 ^ (i - 1)
			warn(`Unexpected request error! Retrying in {retryAfter}s.\nError message: {response :: string}`)
			task.wait(retryAfter) -- exponential backoff
			
			continue
		end
		
		-- for convenience sake...
		response = response :: HttpRequestResponse
		
		-- Update ratelimit
		local headers = response.Headers
		local ratelimitReset = headers["x-ratelimit-reset"]
		if ratelimitReset then
			internal.RateLimitReset = tonumber(ratelimitReset) :: number
			
			local ratelimitRemaining = tonumber(headers["x-ratelimit-remaining"]) :: number
			if ratelimitRemaining < internal.RateLimitRemaining then
				internal.RateLimitRemaining = ratelimitRemaining
			end
			
			if ratelimitRemaining == 0 then
				internal.IsRateLimited = true
			end
			
			-- Ratelimit Reset
			if not internal.RateLimitResetTask then
				internal.RateLimitResetTask = task.delay((tonumber(headers["x-ratelimit-reset-after"]) or 1) + ADDITIONAL_RETRY_WAIT, resetRatelimit, internal) :: any
			end
		end
		
		-- Send success!
		if response.Success then
			break
		end
		
		-- Request sent, but something else went wrong
		local statusCode = response.StatusCode
		
		warn(`Failed to send message. HTTP {statusCode}: {response.StatusMessage}`)
		
		-- 400: Bad Request
		if statusCode == 400 then
			apiFailReason = "BadRequest"
			
			break
			
		-- 401/404: Unauthorized/Invalid Webhook
		elseif statusCode == 401 or statusCode == 404 then
			apiFailReason = "InvalidWebhook"
			internal.IsInvalid = true :: any
			
			break
			
		-- 429: Too Many Requests
		elseif statusCode == 429 then
			apiFailReason = "RateLimited"
			
			internal.IsRateLimited = true
			
			-- Ratelimit Reset
			if not internal.RateLimitResetTask then
				internal.RateLimitResetTask = task.delay((tonumber(headers["x-ratelimit-reset-after"]) or 1) + ADDITIONAL_RETRY_WAIT, resetRatelimit, internal) :: any -- silence another faulty type error
			end
			
			-- Retry after waiting
			if i < SEND_MAX_ATTEMPTS then
				local retryAfter: number = (HttpService:JSONDecode(response.Body).retry_after or 1) + ADDITIONAL_RETRY_WAIT
				warn(`Retrying after {retryAfter}s.`)
				task.wait(retryAfter)
			end
			
		-- Other failure	
		else
			apiFailReason = `HTTP {statusCode}: {response.StatusMessage}`
		end
	end
	
	return success, response, apiFailReason
end

--[[ Module Functions ]]--
--------------------------

--[[
Returns a new <code>Webhook</code> from the given <code>webhookCredentials</code>.

Supports receiving a <code>Secret</code> or <code>string</code> of the webhook URL.
]]
function RDHook.new(webhookCredentials: WebhookCredentials): WebhookObject
	local credentialType = typeof(webhookCredentials)
	if credentialType ~= "string" and credentialType ~= "Secret" then
		error(`invalid webhookCredentials provided. Secret or string expected, got {credentialType}`, 2)
	end
	
	-- Create object
	local object = table.freeze(setmetatable({}, webhookClass.metatable)) :: WebhookObject
	local internal: internalWebhookObj = {
		Credentials = webhookCredentials,
		IsRateLimited = false,
		RateLimitReset = 0,
		RateLimitRemaining = DEFAULT_BUCKET_LIMIT,
		RateLimitResetTask = nil :: thread?,
		IsInvalid = false,
		RequestQueue = {}
	}
	webhookClass.internal[object] = internal
	
	return object
end

return table.freeze(RDHook)
