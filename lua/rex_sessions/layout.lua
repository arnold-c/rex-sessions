-- Queries over the session view and its layout trees.

local M = {}

local function contains_block(node, block_id)
	if node.block_id then
		return node.block_id == block_id
	end
	return contains_block(node.split.before, block_id) or contains_block(node.split.after, block_id)
end

function M.any_block(node)
	return node.block_id or M.any_block(node.split.before)
end

local function active_window(view)
	for _, window in ipairs(view.windows or {}) do
		if window.window_id == view.active_window_id then
			return window
		end
	end
end

-- The window holding the block, in its tiled or a floating layer.
local function holder(view, block_id)
	for _, window in ipairs(view.windows or {}) do
		for _, layer in ipairs(window.layers or {}) do
			if layer.layout and contains_block(layer.layout, block_id) then
				return window
			end
		end
	end
end

-- The window holding the block the key was pressed in. The server's
-- active_window_id can lag the app's selected tab, so prefer the block.
function M.current_window(view, block_id)
	return block_id and holder(view, block_id) or active_window(view)
end

return M
